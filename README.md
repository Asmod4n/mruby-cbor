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
| **Lazy Decoding** | `CBOR::Lazy` for on-demand nested access with result caching |
| **Streaming** | `CBOR.stream` for CBOR sequence reading |
| **Performance** | ~30% faster than msgpack; 1.3–3× faster than simdjson for selective access |

### ⚠️ Limitations

- No indefinite-length item support (RFC 8949 Section 4.2.1)

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

`decode_lazy` returns a `CBOR::Lazy` object wrapping the raw buffer **without decoding**. Navigate with `[]` or `dig`, then call `.value` when you need the actual value.
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

**Performance:** Access is O(n) only in skipped elements, not the full document. Results are cached for O(1) repeated access.
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

  # Called after allocation during decode
  def from_allocate
    puts "Person #{@name} loaded"
    self
  end
end

# Register with a tag number (user-defined: 1000+)
CBOR.register_tag(1000, Person)

person = Person.new
person.name = "Alice"
person.age = 30

encoded = CBOR.encode(person)
decoded = CBOR.decode(encoded)  # => Person object
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
# 1. Default: convert to strings (no tag)
CBOR.no_symbols

# 2. Use tag 39 + string
CBOR.symbols_as_string

# 3. Use tag 39 + uint32 (mruby-to-mruby only)
CBOR.symbols_as_uint32
sym = :hello
encoded = CBOR.encode(sym)
decoded = CBOR.decode(encoded)  # => :hello
```

> **⚠️ Warning:** `symbols_as_uint32` is mruby instance–specific. Only use it when both encoder and decoder run on the same mruby executable and when all symbols are interned at compile time, see https://github.com/mruby/mruby/blob/master/doc/guides/symbol.md#preallocate-symbols

---

### Streaming

Read a sequence of CBOR documents from any IO-like object:
```ruby
File.open("data.cbor", "rb") do |f|
  CBOR.stream(f) do |doc|
    puts doc.value.inspect
  end
end

# Or as an enumerator
docs = CBOR.stream(io).map(&:value)
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

## 🔗 Specification

- **CBOR (RFC 8949):** https://tools.ietf.org/html/rfc8949
- **Test Vectors:** Official test suite in `/test-vectors`

---

## 📄 License

Apache License 2.0
