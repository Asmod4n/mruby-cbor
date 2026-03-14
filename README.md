# mruby-cbor

> A **fast, spec-compliant** [CBOR](https://cbor.io) (RFC 8949) implementation for [mruby](https://github.com/mruby/mruby)

![](https://img.shields.io/badge/RFC-8949-blue) ![](https://img.shields.io/badge/License-Apache--2.0-brightgreen)

---

## ✨ Features

| Feature | Details |
|---------|---------|
| **Core Types** | Integers, floats, strings, byte strings, arrays, maps, booleans, nil |
| **BigInt Support** | Tags 2/3 (RFC 8949) when compiled with `MRB_USE_BIGINT` |
| **Float Precision** | Float16/32/64 with subnormals, Inf, and NaN |
| **Shared References** | Tags 28/29 for deduplication, including cyclic structures |
| **Zero-Copy Decoding** | Both eager and lazy decoding operate directly on the input buffer without copying |
| **Lazy Decoding** | `CBOR::Lazy` for on-demand nested access with key and result caching |
| **Streaming** | `CBOR.stream` for CBOR sequence reading |
| **Performance** | ~30% faster than msgpack; 1.3–3× faster than simdjson for selective access |

### ⚠️ Limitations & Design Decisions

| Limitation | Reason |
|-----------|--------|
| No indefinite-length items | Use CBOR.stream mode instead. |

**Determinism Guarantees:**
- Encoding is deterministic *within a single mruby build*
- Hash field order follows insertion order (per mruby hash impl)
- Float width (16/32/64) is compile-time fixed via `MRB_USE_FLOAT32`
- Symbol encoding strategy is global; don't mix `no_symbols` / `symbols_as_string` / `symbols_as_uint32` in the same program
- **Not deterministic across builds** if you rebuild mruby with different CFLAGS or config

**Recursion Depth Limits:**
Default `CBOR_MAX_DEPTH` depends on mruby profile:
- `MRB_PROFILE_MAIN` / `MRB_PROFILE_HIGH`: 512
- `MRB_PROFILE_BASELINE`: 64
- Constrained / other: 32

Exceeding this raises `RuntimeError: "CBOR nesting depth exceeded"`. Override by setting `CBOR_MAX_DEPTH` at compile time.

---

## 📊 Performance Notes

- **Encoding:** ~30% faster than msgpack (SBO + incremental writes)
- **Lazy decoding:** 1.3–3× faster than simdjson for selective access
- **Shared refs:** Tags 28/29 deduplication is O(1) amortized
- **Float encoding:** No overhead; width selection happens once per value at encode time

**When to use lazy decoding:**
- Decoding large payloads where you only access a subset of fields
- Streaming/telemetry where you care about specific fields
- Network protocols where you validate before deserializing

**When to use eager decoding:**
- Small payloads
- You need the full object in memory instantly
- Simplicity over optimization

---

## 🚀 Quick Start

### Basic Encode/Decode
```ruby
# Encode
buf = CBOR.encode({ "hello" => [1, 2, 3], "ok" => true })

# Decode
obj = CBOR.decode(buf)
# => {"hello" => [1, 2, 3], "ok" => true}

# Lazy decode – only parses what you access
lazy = CBOR.decode_lazy(buf)
lazy["hello"][1].value  # => 2 (constant-time after first access)
```

---

## 📖 Usage Guide

### CBOR::Lazy – On-Demand Access

`decode_lazy` returns a `CBOR::Lazy` object wrapping the raw buffer **without decoding the value**. Navigate with `[]` or `dig`, then call `.value` when you need the actual value.
```ruby
lazy = CBOR.decode_lazy(big_payload)

# Navigate nested structures
status = lazy["statuses"][0]["text"].value

# Equivalent: use `dig` for safety
status = lazy.dig("statuses", 0, "text").value

# Error handling
lazy["missing"]              # => KeyError (raises)
lazy.dig("missing", "text")  # => nil (safe)
```

**Performance:** Access is O(n) only in skipped elements, not the full document. Keys and Results are cached for O(1) repeated access.
```ruby
# Repeated access uses cache
inner = lazy["outer"]["inner"].value
inner2 = lazy["outer"]["inner"].value
assert_same inner, inner2  # Same object (cached)
```

---

### Shared References (Tags 28/29)

Eliminate duplication and represent cyclic structures.
```ruby
# Encode with deduplication
shared_array = [1, 2, 3]
buf = CBOR.encode(
  { "x" => shared_array, "y" => shared_array },
  sharedrefs: true
)

# Decode: identity is preserved
decoded = CBOR.decode(buf)
decoded["x"].equal?(decoded["y"])  # => true ✓

# Works with lazy decoding too
lazy = CBOR.decode_lazy(buf)
lazy["x"].value.equal?(lazy["y"].value)  # => true ✓
```

**Cyclic Structures:**
```ruby
cyclic = []
cyclic << cyclic

buf = CBOR.encode(cyclic, sharedrefs: true)
result = CBOR.decode(buf)

result.equal?(result[0])  # => true (self-referential)
```

---

### Custom Tags & Type Registration

Register your own classes for CBOR encoding/decoding.
```ruby
class Person
  attr_accessor :name, :age

  # Declare which fields to encode/decode and their expected CBOR types
  native_ext_type :@name, CBOR::Type::String
  native_ext_type :@age, CBOR::Type::Integer

  # Called after decoding (optional)
  def _after_decode
    puts "Person #{@name} loaded"
    self
  end

  # Called before encoding (optional)
  # Must return self or a modified object
  def _before_encode
    @age += 1 if @age < 18  # Example transformation
    self
  end
end

# Register with a tag number (user-defined: 1000+)
CBOR.register_tag(1000, Person)

person = Person.new
person.name = "Alice"
person.age = 30

encoded = CBOR.encode(person)
decoded = CBOR.decode(encoded)  # => Person object, after_decode called
```

**Available Types:**
- `CBOR::Type::UnsignedInt`
- `CBOR::Type::NegativeInt`
- `CBOR::Type::String` (UTF-8 text)
- `CBOR::Type::Bytes` (raw bytes)
- `CBOR::Type::Array`, `CBOR::Type::Map`
- `CBOR::Type::Tagged` (for Bigint, your own registered Tags)
- `CBOR::Type::Simple` (nil, false, true, Floats)

Convenience Types:
- `CBOR::Type::BytesOrString`
- `CBOR::Type::Integer`

---

### Symbol Handling

Three strategies for encoding Ruby symbols:

```ruby
# 1. Default: strip symbols (no tag, no round-trip)
CBOR.no_symbols
sym = :hello
encoded = CBOR.encode(sym)  # Encodes as plain string "hello"
decoded = CBOR.decode(encoded)  # => "hello" (not a symbol!)

# 2. Use tag 39 + string (RFC 8949, interoperable)
CBOR.symbols_as_string
sym = :hello
encoded = CBOR.encode(sym)
decoded = CBOR.decode(encoded)  # => :hello (symbol preserved)

# 3. Use tag 39 + uint32 (mruby presym only, fastest)
CBOR.symbols_as_uint32
sym = :hello
encoded = CBOR.encode(sym)
decoded = CBOR.decode(encoded)  # => :hello (symbol preserved, same mruby only)
```

**Mode Comparison:**

| Mode | Encoding | Interop | Round-trip | Speed |
|------|----------|---------|-----------|-------|
| `no_symbols` | Plain string | ✅ All | ❌ No | Fast |
| `symbols_as_string` | Tag 39 + string | ✅ All | ✅ Yes | Good |
| `symbols_as_uint32` | Tag 39 + uint32 | ❌ mruby only | ✅ Yes | Fastest |

> **⚠️ Warning:** `symbols_as_uint32` requires:
> - **Same mruby build** — encoder and decoder must use the same mruby executable (same `libmruby.a`)
> - **Compile-time symbols** — all symbols must be interned at build time (see [presym docs](https://github.com/mruby/mruby/blob/master/doc/guides/symbol.md#preallocate-symbols))
> - **No runtime symbol creation** — decoding fails if the symbol ID doesn't exist in the decoder's presym table
>
> Use only for internal mruby-to-mruby IPC on the same build. For external/user data, use `symbols_as_string`.

---

### Streaming

Read a sequence of CBOR documents from any File-like object:
```ruby
File.open("data.cbor", "rb") do |f|
  CBOR.stream(f) do |doc|
    puts doc.value.inspect
  end
end

# Or as an enumerator
docs = CBOR.stream(f).map(&:value)
```

---

## 📦 Installation

Add to your `build_config.rb`:
```ruby
conf.gem github: "Asmod4n/mruby-cbor"
```

Then build:
```bash
rake compile
rake test
```

---

## ⚠️ Error Handling

| Error | When | Example |
|-------|------|---------|
| `ArgumentError` | Invalid encode options | `CBOR.encode(obj, bad_option: true)` |
| `RangeError` | Integer out of bounds | Encoding a Bigint larger than uint64 |
| `RuntimeError` | Nesting depth exceeded | Deeply nested structures beyond `CBOR_MAX_DEPTH` |
| `RuntimeError` | Truncated/invalid CBOR | `CBOR.decode(incomplete_buffer)` |
| `TypeError` | Type mismatch in registered tags | Field marked as String gets an Array |
| `KeyError` | Lazy access to missing key | `lazy["nonexistent"]` (use `.dig` to get nil instead) |
| `NotImplementedError` | Presym on non-presym mruby | `CBOR.symbols_as_uint32` on build without presym |

---

## 🔗 Specification

- **CBOR (RFC 8949):** https://tools.ietf.org/html/rfc8949
- **Test Vectors:** Official test suite in `/test-vectors`

---

## 📄 License

Apache License 2.0