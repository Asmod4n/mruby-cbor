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
| **Streaming** | `CBOR.stream` for CBOR sequences from strings, files, and sockets |
| **Performance** | ~30% faster than msgpack; 1.3–3× faster than simdjson for selective access |

### ⚠️ Limitations & Design Decisions

| Limitation | Reason |
|-----------|--------|
| No indefinite-length items | Use CBOR.stream mode instead. |

**Determinism Guarantees:**
- Encoding is deterministic *within a single mruby build*
- Hash field order follows insertion order (per mruby hash impl)
- Float width is compile-time fixed via `MRB_USE_FLOAT32` (f32 build) or defaults to f64
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
- **Float encoding:** Width is fixed at compile time; no runtime overhead

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

**Performance:** Access is O(n) only in skipped elements, not the full document. Keys and results are cached for O(1) repeated access.
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

Register your own classes for CBOR encoding/decoding. The `native_ext_type` DSL declares which ivars to encode/decode and their expected Ruby type. Any Ruby class works as a type constraint — including other registered classes, enabling nested structures.

```ruby
class Address
  native_ext_type :@street, String
  native_ext_type :@city,   String
end

CBOR.register_tag(1001, Address)

class Person
  native_ext_type :@name,    String
  native_ext_type :@age,     Integer
  native_ext_type :@address, Address   # nested registered class

  # Called after decoding (optional)
  def _after_decode
    puts "Person #{@name} loaded"
    self
  end

  # Called before encoding (optional). Must return self or a modified object.
  def _before_encode
    @age += 1 if @age < 18
    self
  end
end

CBOR.register_tag(1000, Person)

addr = Address.new
addr.instance_variable_set(:@street, "Main St")
addr.instance_variable_set(:@city, "Berlin")

person = Person.new
person.instance_variable_set(:@name, "Alice")
person.instance_variable_set(:@age, 30)
person.instance_variable_set(:@address, addr)

encoded = CBOR.encode(person)
decoded = CBOR.decode(encoded)  # => Person object, _after_decode called

decoded.instance_variable_get(:@name)                            # => "Alice"
decoded.instance_variable_get(:@address).class                  # => Address
decoded.instance_variable_get(:@address).instance_variable_get(:@city)  # => "Berlin"
```

**Type constraints use standard Ruby classes:**

| Schema type | Accepts |
|-------------|---------|
| `String` | UTF-8 strings and byte strings |
| `Integer` | Integer values (fixnum or bigint) |
| `Float` | Floating-point values |
| `Array` | Arrays |
| `Hash` | Maps |
| `TrueClass` / `FalseClass` | Booleans |
| `NilClass` | nil |
| Any registered class | Instances of that class (or subclasses) |

Type checking uses `is_a?`, so inheritance works: a schema of `Numeric` accepts both `Integer` and `Float`, and a schema of `Animal` accepts any subclass of `Animal`.

Fields absent from a decoded payload are silently skipped — only declared ivars are populated (allowlist model). Extra fields in the payload are ignored.

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

`CBOR.stream` reads a sequence of CBOR documents from a String, File, or socket. It dispatches automatically based on the source type.

**From a String:**
```ruby
buf = CBOR.encode("hello") + CBOR.encode("world")

CBOR.stream(buf) do |doc|
  puts doc.value
end

# With offset (skip the first document)
CBOR.stream(buf, skip) { |doc| ... }

# As an enumerator
CBOR.stream(buf).map(&:value)  # => ["hello", "world"]
```

**From a File:**
```ruby
File.open("data.cbor", "rb") do |f|
  CBOR.stream(f) do |doc|
    puts doc.value.inspect
  end
end

# With byte offset into the file
File.open("data.cbor", "rb") do |f|
  CBOR.stream(f, 1024) { |doc| ... }
end
```

**From a Socket (block form — drives the read loop):**
```ruby
sock = TCPSocket.new("host", 1234)

CBOR.stream(sock) do |doc|
  handle(doc.value)
end
```

**From a Socket (no-block form — returns a `CBOR::StreamDecoder`):**

Use this when you control the read loop yourself, e.g. in an event-driven or async context:

```ruby
decoder = CBOR::StreamDecoder.new { |doc| handle(doc.value) }

# Feed chunks as they arrive
while chunk = sock.recv(4096)
  decoder.feed(chunk)
end
```

`StreamDecoder` buffers only the minimum bytes needed to complete the current document. Once a document is decoded and yielded, its bytes are discarded immediately — each `CBOR::Lazy` owns its own view of the data and is independent of the decoder's internal buffer.

**Dispatch rules:**

| Source type | Detection | Behaviour |
|-------------|-----------|-----------|
| String-like | responds to `bytesize` and `byteslice` | Walks buffer directly, no copy |
| Socket-like | responds to `recv` | Accumulates chunks, yields complete docs |
| File-like   | responds to `seek` and `read` | Uses `seek`+`read` with doubling read-ahead |

---

## 📦 Installation

Add to your `build_config.rb`:
```ruby
conf.gem mgem: "mruby-cbor"
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
| `TypeError` | Type mismatch in registered tags | Field declared as `String` receives an `Array` |
| `TypeError` | Unknown stream source | `CBOR.stream(42)` |
| `KeyError` | Lazy access to missing key | `lazy["nonexistent"]` (use `.dig` to get nil instead) |
| `NotImplementedError` | Presym on non-presym mruby | `CBOR.symbols_as_uint32` on build without presym |

---

## 🔗 Specification

- **CBOR (RFC 8949):** https://tools.ietf.org/html/rfc8949
- **Test Vectors:** Official test suite in `/test-vectors`

---

## 📄 License

Apache License 2.0