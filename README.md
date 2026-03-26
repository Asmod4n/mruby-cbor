# mruby-cbor

> A **fast, spec-compliant** [CBOR](https://cbor.io) (RFC 8949) implementation for [mruby](https://github.com/mruby/mruby)

![](https://img.shields.io/badge/RFC-8949-blue) ![](https://img.shields.io/badge/License-Apache--2.0-brightgreen)

---

## ✨ Features

| Feature | Details |
|---------|---------|
| **Core Types** | Integers, floats, strings, byte strings, arrays, maps, booleans, nil |
| **BigInt Support** | Tags 2/3 (RFC 8949) when compiled with `MRB_USE_BIGINT` |
| **Float Precision** | Preferred serialization: f16→f32→f64 (smallest lossless width). NaN canonicalized to `0xF97E00`. Pure bit-pattern arithmetic, zero FP ops. |
| **Shared References** | Tags 28/29 for deduplication, including cyclic structures |
| **Zero-Copy Decoding** | Both eager and lazy decoding operate directly on the input buffer without copying |
| **Lazy Decoding** | `CBOR::Lazy` for on-demand nested access with key and result caching |
| **Streaming** | `CBOR.stream` for CBOR sequences from strings, files, and sockets |
| **Class / Module Encoding** | Tag 49999 — classes and modules round-trip automatically |
| **Proc-based Tag Registration** | Register encode/decode procs for any type, including builtins with C state |
| **Performance** | ~30% faster than msgpack; 1.3–3× faster than simdjson for selective access |

### ⚠️ Limitations & Design Decisions

| Limitation | Reason |
|-----------|--------|
| No indefinite-length items | Use CBOR.stream mode instead. |

**Determinism Guarantees:**
- Encoding is deterministic *within a single mruby build*
- Hash field order follows insertion order (per mruby hash impl)
- Float preferred width (f16/f32/f64) is determined entirely by the value's bit pattern — same value always produces the same wire bytes
- `MRB_USE_FLOAT32` builds cap at f32; f16 preferred serialization still applies within that cap
- NaN always encodes as canonical `0xF97E00` (quiet NaN, f16), matching RFC 8949 Appendix B and the cbor2 reference implementation
- Symbol encoding strategy is global; don't mix `no_symbols` / `symbols_as_string` / `symbols_as_uint32` in the same program
- **Not deterministic across builds** if you rebuild mruby with different CFLAGS or config

**Recursion Depth Limits:**
Default `CBOR_MAX_DEPTH` depends on mruby profile:
- `MRB_PROFILE_MAIN` / `MRB_PROFILE_HIGH`: 128
- `MRB_PROFILE_BASELINE`: 64
- Constrained / other: 32

Exceeding this raises `RuntimeError: "CBOR nesting depth exceeded"`. Override by setting `CBOR_MAX_DEPTH` at compile time.

---

## 📊 Performance Notes

- **Encoding:** ~30% faster than msgpack (SBO + incremental writes)
- **Lazy decoding:** 1.3–3× faster than simdjson for selective access
- **Float encoding:** Preferred serialization (f16→f32→f64) uses pure bit-pattern arithmetic — a handful of integer comparisons and masks. Zero floating-point operations. Negligible overhead compared to the buffer write itself.

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

### Float Encoding

Floats use **preferred serialization** (RFC 8949 §4.1): the smallest CBOR float width that represents the value losslessly. Width is chosen by pure bit-pattern arithmetic with zero floating-point operations.

```ruby
CBOR.encode(0.0).bytesize      # => 3  (f16: F9 00 00)
CBOR.encode(1.0).bytesize      # => 3  (f16: F9 3C 00)
CBOR.encode(1.5).bytesize      # => 3  (f16: F9 3E 00)
CBOR.encode(1.0e10).bytesize   # => 5  (f32)
CBOR.encode(3.14).bytesize     # => 9  (f64)

CBOR.encode(Float::INFINITY)   # => "\xF9\x7C\x00"  (f16)
CBOR.encode(-Float::INFINITY)  # => "\xF9\xFC\x00"  (f16)
CBOR.encode(Float::NAN)        # => "\xF9\x7E\x00"  (canonical quiet NaN, always)
```

Width selection rules:

| Value category | Encoding | Condition |
|----------------|----------|-----------|
| NaN (any payload/sign) | f16 `0x7E00` | Canonicalized per RFC 8949 App. B |
| ±Inf, ±0 | f16 | Always |
| f16 normal | f16 | f32 exp ∈ [113..142] and low 13 f32 mant bits = 0 |
| f16 subnormal | f16 | f32 exp ∈ [103..112] and bit fit is exact |
| Fits losslessly in f32 | f32 | Low 29 f64 mant bits = 0 and exp in f32 range |
| Everything else | f64 | |

`MRB_USE_FLOAT32` builds start at f32 and still try f16 first.

---

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
  native_ext_type :@has_kids, TrueClass, FalseClass

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
person.instance_variable_set(:@has_kids, true)

encoded = CBOR.encode(person)
decoded = CBOR.decode(encoded)  # => Person object, _after_decode called

decoded.instance_variable_get(:@name)                           # => "Alice"
decoded.instance_variable_get(:@has_kids)                       # => true
decoded.instance_variable_get(:@address).class                  # => Address
decoded.instance_variable_get(:@address).instance_variable_get(:@city)  # => "Berlin"
```

**Type constraints use standard Ruby classes:**

| Schema type | Accepts |
|-------------|---------|
| `String` | UTF-8 strings and byte strings |
| `Integer` | Integer values (fixnum or bigint) |
| `Float` | Floating-point values |
| `Numeric` | Any Numeric value |
| `Array` | Arrays |
| `Hash` | Maps |
| `TrueClass` / `FalseClass` | Booleans |
| `NilClass` | nil |
| Any registered class | Instances of that class (or subclasses) |

Type checking uses `is_a?`, so inheritance works: a schema of `Numeric` accepts both `Integer` and `Float`, and a schema of `Animal` accepts any subclass of `Animal`.

Fields absent from a decoded payload are silently skipped — only declared ivars are populated (allowlist model). Extra fields in the payload are ignored.

---

### Class and Module Encoding (Tag 49999)

Classes and modules are encoded automatically using a private tag (49999) wrapping the constant path as a UTF-8 string. On decode, the string is resolved back to the constant via `String#constantize`.

```ruby
CBOR.encode(ArgumentError)         # encodes as tag(49999, "ArgumentError")
CBOR.decode(buf)                   # => ArgumentError (the class itself)

CBOR.encode(CBOR::UnhandledTag)    # => tag(49999, "CBOR::UnhandledTag")

# Classes round-trip inside any structure
h = { "type" => StandardError, "code" => 42 }
CBOR.decode(CBOR.encode(h))["type"]  # => StandardError
```

Anonymous classes and modules raise `ArgumentError` on encode since they have no resolvable name.

This is mruby-to-mruby only — the constant path syntax (`::` separator) is Ruby-specific and other runtimes will not know how to resolve it.

---

### Proc-based Tag Registration

For types with internal C state that cannot be subclassed or have ivars added — such as `Exception`, `Time`, or any `MRB_TT_DATA` object — use `register_tag` with a block instead of a class. The block DSL declares an encode proc (extracts state into a plain CBOR-encodable value) and a decode proc (reconstructs the object from that value), each with a type constraint.

```ruby
CBOR.register_tag(tag_number) do
  encode EncodeType do |obj|
    # return any CBOR-encodable value
  end

  decode DecodeType do |payload|
    # reconstruct and return the object
    # payload is guaranteed to be a kind_of? DecodeType
  end
end
```

**Encode type matching uses `kind_of?`**, so registering `Exception` as the encode type will match `StandardError`, `ArgumentError`, and any other subclass.

**Natively-encoded types are rejected** as encode types — `String`, `Integer`, `Float`, `Array`, `Hash`, `TrueClass`, `FalseClass`, `NilClass`, `Symbol`, `Class`, and `Module` are all handled by the encoder's core switch and cannot be overridden via the proc path. `Exception` and user-defined classes are allowed.

#### Exception serialization

```ruby
CBOR.register_tag(50000) do
  encode Exception do |e|
    [e.class, e.message, e.backtrace]
  end

  decode Array do |a|
    exc = a[0].new(a[1])
    exc.set_backtrace(a[2]) if a[2]
    exc
  end
end

buf = begin
  raise ArgumentError, "something went wrong"
rescue => e
  CBOR.encode(e)
end

exc = CBOR.decode(buf)
raise exc  # re-raises ArgumentError with original message and backtrace
```

#### Time serialization (optional, requires mruby-time)

```ruby
CBOR.register_tag(1) do
  encode Time do |t|
    t.to_f
  end

  decode Float do |v|
    Time.at(v)
  end
end

CBOR.encode(Time.now)   # => tag(1, <f16/f32/f64 epoch float>)
CBOR.decode(buf)        # => Time object
```

Tag 1 is the official RFC 8949 epoch-based time tag. Since `mruby-time` is optional, users who need it wire it up themselves.

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
| `ArgumentError` | Reserved tag number | `CBOR.register_tag(39, MyClass)` |
| `ArgumentError` | Encoding anonymous class/module | `CBOR.encode(Class.new)` |
| `RangeError` | Integer out of bounds | Encoding a Bigint larger than uint64 |
| `RuntimeError` | Nesting depth exceeded | Deeply nested structures beyond `CBOR_MAX_DEPTH` |
| `RuntimeError` | Truncated/invalid CBOR | `CBOR.decode(incomplete_buffer)` |
| `TypeError` | Type mismatch in registered tags | Field declared as `String` receives an `Array` |
| `TypeError` | Proc tag decode type mismatch | Decode proc received wrong payload type |
| `TypeError` | Registering natively-encoded type as proc encode type | `encode String do ...` |
| `TypeError` | Unknown stream source | `CBOR.stream(42)` |
| `KeyError` | Lazy access to missing key | `lazy["nonexistent"]` (use `.dig` to get nil instead) |
| `NameError` | Tag 49999 payload resolves to unknown constant | Decoding a class name not defined on this side |
| `NotImplementedError` | Presym on non-presym mruby | `CBOR.symbols_as_uint32` on build without presym |

---

## 🔗 Specification

- **CBOR (RFC 8949):** https://tools.ietf.org/html/rfc8949
- **Test Vectors:** Official test suite in `/test-vectors`

---

## 📄 License

Apache License 2.0