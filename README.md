# mruby-cbor

Fast, spec-compliant CBOR encoding and decoding for mruby.

[![RFC 8949](https://img.shields.io/badge/RFC-8949-blue)](https://tools.ietf.org/html/rfc8949) [![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-brightgreen)](#license)

---

## Table of Contents

- [Why CBOR?](#why-cbor)
- [Highlights](#highlights)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Encoding & Decoding](#encoding--decoding)
- [Lazy Decoding (`CBOR::Lazy`)](#lazy-decoding-cborlazy)
- [Path Queries (`CBOR::Path`)](#path-queries-cborpath)
- [Custom Types](#custom-types)
  - [Schema DSL (`native_ext_type`)](#schema-dsl-native_ext_type)
  - [Proc-Based](#proc-based)
  - [Unknown Tags](#unknown-tags)
- [Symbols](#symbols)
- [Streaming](#streaming)
- [Fast Path (Same-Build Only)](#fast-path-same-build-only)
- [Diagnostic Notation](#diagnostic-notation)
- [C-API](#c-api)
- [Errors](#errors)
- [Interoperability](#interoperability)
- [Further Reading](#further-reading)
- [License](#license)

---

## Why CBOR?

CBOR ([RFC 8949](https://tools.ietf.org/html/rfc8949)) is a binary data format with roughly the same data model as JSON. Compared to JSON: smaller wire size, faster parsing, and distinct integer/float and text/byte types. Compared to msgpack: a spec-compliant tag system for custom types, shared references for cyclic structures, and a clearly defined diagnostic notation.

## Highlights

- **RFC 8949 compliant** — interoperates with Go (`fxamacker/cbor`), Python, Rust, and any spec-compliant decoder
- **Zero-copy lazy decoding** — parse only what you access via `CBOR::Lazy`
- **JSON-pointer-style queries** — `CBOR::Path` with `[*]` wildcard support
- **Shared references** — Tag 28/29 for deduplication and cyclic structures
- **Custom types** — schema DSL (`native_ext_type`) or proc-based registration
- **Streaming** — decode CBOR sequences from strings, files, or sockets
- **Diagnostic notation** — RFC 8949 §8.1 human-readable output
- **Hardened** — UTF-8 validation, depth limits, overflow protection, fuzz-tested

For deep-dive details (determinism guarantees, internal algorithms, performance tuning), see [`wiki/Internals`](../../wiki/Internals).

---

## Installation

Add to your mruby `build_config.rb`:

```ruby
MRuby::Build.new do |conf|
  conf.gem mgem: "mruby-cbor"
end
```

Build and test:

```bash
rake compile
rake test
```

---

## Quick Start

```ruby
# Encode and decode
buf = CBOR.encode({ "users" => [{ "id" => 1, "name" => "Alice" }], "count" => 1 })
CBOR.decode(buf)
# => {"users"=>[{"id"=>1, "name"=>"Alice"}], "count"=>1}

# Lazy decode — only the path you touch is parsed
lazy = CBOR.decode_lazy(buf)
lazy["users"][0]["name"].value           # => "Alice"

# JSON-pointer-style queries
CBOR::Path.compile("$.users[*].name").at(lazy)   # => ["Alice"]

# Shared references — preserve identity, encode cycles
shared = [1, 2, 3]
result = CBOR.decode(CBOR.encode({ "a" => shared, "b" => shared }, sharedrefs: true))
result["a"].equal?(result["b"])          # => true
```

---

## Encoding & Decoding

```ruby
CBOR.encode(obj)                       # Canonical CBOR bytes
CBOR.encode(obj, sharedrefs: true)     # With Tag 28/29 deduplication
CBOR.decode(buf)                       # Eager decode — full Ruby value
CBOR.decode_lazy(buf)                  # CBOR::Lazy wrapper, no parsing yet
CBOR.diagnose(buf)                     # RFC 8949 §8.1 diagnostic notation
```

Supported out of the box: integers (incl. bignums), floats (`f16`/`f32`/`f64` preferred serialization), text and binary strings, arrays, hashes, booleans, `nil`, symbols, classes/modules, and any registered custom type.

---

## Lazy Decoding (`CBOR::Lazy`)

Wrap a buffer without decoding it; pay only for the bytes you actually read.

```ruby
lazy = CBOR.decode_lazy(big_payload)

# Navigate by chaining
lazy["response"]["data"][0]["id"].value

# `dig` is safe — returns nil for missing keys instead of raising
lazy.dig("maybe", "missing")             # => nil

# Negative array indices work
lazy["items"][-1].value

# Repeated access is cached — same object back each time
# `inspect` returns diagnostic notation for the wrapped slice
puts lazy["items"][0].inspect            # => `{"id":1,...}`
```

Performance scales with the bytes you actually touch — perfect for large payloads where you only need a few fields.

---

## Path Queries (`CBOR::Path`)

JSON-pointer-style path queries with `[*]` wildcard support. Compiled paths are reusable across multiple lazies.

```ruby
data = {
  "users" => [
    { "name" => "Alice", "age" => 30 },
    { "name" => "Bob",   "age" => 25 }
  ]
}
lazy = CBOR.decode_lazy(CBOR.encode(data))

# Plain point query
CBOR::Path.compile("$.users[0].name").at(lazy)
# => "Alice"

# Single wildcard
CBOR::Path.compile("$.users[*].name").at(lazy)
# => ["Alice", "Bob"]

# Nested wildcards — result mirrors the structure
CBOR::Path.compile("$.teams[*].members[*].name").at(lazy)
# => [["Alice", "Bob"], ["Carol"]]

# Compile once, reuse across documents
path = CBOR::Path.compile("$.items[*].id")
ids1 = path.at(lazy_a)
ids2 = path.at(lazy_b)
```

Grammar: `$`, `.identifier`, `[index]` (incl. negative), `["string key"]`, `[*]` wildcards. Path queries share `CBOR::Lazy`'s key cache, so repeated lookups against the same document are O(1) per step.

---

## Custom Types

Two ways to register a class under a CBOR tag:

### Schema DSL (`native_ext_type`)

For plain Ruby classes whose state lives in instance variables:

```ruby
class Person
  attr_accessor :name, :age, :email

  native_ext_type :@name,  String
  native_ext_type :@age,   Integer
  native_ext_type :@email, String, NilClass    # nullable union

  def initialize(name, age, email = nil)
    @name, @age, @email = name, age, email
  end

  # Optional hooks — called automatically
  def _before_encode; ...; self; end
  def _after_decode;  ...; self; end
end

CBOR.register_tag(1000, Person)
```

Type constraints accept any class plus `NilClass`. Inheritance works — `Numeric` matches both `Integer` and `Float`. Extra fields in the payload are silently ignored (allowlist model — security-positive default).

### Proc-Based

For types you can't add `native_ext_type` to (e.g. `Exception`, `Time`):

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
```

Encode-type matching uses `kind_of?`. Built-in types (`String`, `Integer`, `Array`, etc.) cannot be registered as encode targets — they're handled by the core encoder. `Exception` is explicitly allowed.

### Unknown Tags

Tags you haven't registered decode as `CBOR::UnhandledTag` objects with `#tag` and `#value` readers, rather than raising. This keeps decoders forward-compatible with newer schemas.

---

## Symbols

Three encoding strategies, choose at runtime:

```ruby
CBOR.no_symbols           # Default. Encode as plain string. No round-trip.
CBOR.symbols_as_string    # Tag 39 + string.  RFC 8949 compatible.  Round-trip.
CBOR.symbols_as_uint32    # Tag 39 + uint32.  mruby-only, fastest.   Round-trip.
```

Use `symbols_as_string` for cross-language interop. `symbols_as_uint32` is faster but only works between mruby builds with identical presym tables — never use it for data that crosses build boundaries.

---

## Streaming

Decode multiple concatenated CBOR documents from any source:

```ruby
# String of concatenated documents
CBOR.stream(buf) { |doc| process(doc.value) }

# File (with adaptive readahead)
File.open("data.cbor", "rb") { |f| CBOR.stream(f) { |doc| ... } }

# Socket
CBOR.stream(socket) { |doc| handle(doc.value) }

# Manual feed for async frameworks
decoder = CBOR::StreamDecoder.new { |doc| handle(doc.value) }
decoder.feed(chunk)
```

Each yielded `doc` is a `CBOR::Lazy`. The dispatch is duck-typed — anything responding to `bytesize`/`byteslice` is a string, anything responding to `seek`/`read` is a file, anything responding to `recv` is a socket.

`CBOR.doc_end(buf, offset = 0)` returns the byte offset of the end of the first complete document, or `nil` if the buffer is truncated. Used internally by `stream` and exposed for custom framing.

---

## Fast Path (Same-Build Only)

For high-throughput internal use where both encoder and decoder are the **same mruby binary**:

```ruby
buf = CBOR.encode_fast(obj)
obj = CBOR.decode_fast(buf)
```

Trades wire portability for speed: integers and floats use fixed native widths, strings always emit as major 2 (byte string), no UTF-8 validation. Roughly 30% faster on typical structured-message payloads.

> [!IMPORTANT]
> Buffers produced by `encode_fast` must only be decoded by `decode_fast` on a binary with identical `MRB_INT_BIT` and `MRB_USE_FLOAT32` settings. Otherwise data is silently corrupted with no error raised. **Never use `encode_fast` for cross-network, cross-build, or persisted data.**

Registered tags, bigints, `UnhandledTag`, and proc-tag types fall back to canonical encoding transparently — `encode_fast` never raises on an unsupported type.

---

## Diagnostic Notation

```ruby
CBOR.diagnose(CBOR.encode(1.0))           # => "1.0_1"   (suffix _1/_2/_3 = float width)
CBOR.diagnose(CBOR.encode(3.14))          # => "3.14_3"
CBOR.diagnose(CBOR.encode(Float::NAN))    # => "NaN_1"
CBOR.diagnose(CBOR.encode("hello"))       # => '"hello"'
CBOR.diagnose("\xc1\x1a\x51\x4b\x67\xb0") # => "1(1363896240)"
```

Works on `MRB_NO_FLOAT` builds — exact rational arithmetic for f16/f32, hex-float notation for f64.

---

## C API

Public C header at `<mruby/cbor.h>`:

```c
mrb_value mrb_cbor_encode(mrb_state *mrb, mrb_value obj);
mrb_value mrb_cbor_encode_sharedrefs(mrb_state *mrb, mrb_value obj);
mrb_value mrb_cbor_encode_fast(mrb_state *mrb, mrb_value obj);
mrb_value mrb_cbor_decode(mrb_state *mrb, mrb_value buf);
mrb_value mrb_cbor_decode_lazy(mrb_state *mrb, mrb_value buf);
mrb_value mrb_cbor_lazy_value(mrb_state *mrb, mrb_value lazy);
mrb_value mrb_cbor_decode_fast(mrb_state *mrb, mrb_value buf);
mrb_value mrb_cbor_doc_end(mrb_state *mrb, mrb_value buf, mrb_int offset);
void      mrb_cbor_register_tag(mrb_state *mrb, uint64_t tag_num, struct RClass *klass);
```

---

## Errors

| Error | Cause |
|-------|-------|
| `ArgumentError`        | Invalid option, anonymous class, reserved tag number |
| `RangeError`           | Integer overflow, length out of range, buffer bounds violation |
| `RuntimeError`         | Malformed CBOR, depth exceeded, sharedref cycle in lazy resolution |
| `TypeError`            | Type mismatch in registered tag, wrong tag payload type |
| `KeyError`             | Lazy map access to missing key (use `dig` for safe access) |
| `IndexError`           | Lazy array out of bounds, invalid sharedref index |
| `NameError`            | Tag 49999 resolves to unknown constant |
| `NotImplementedError`  | Indefinite-length item, presym unavailable for `symbols_as_uint32` |

---

## Interoperability

Tested against `fxamacker/cbor` v2 (Go) in strict mode — preferred serialization, UTF-8 validation, duplicate-key rejection, indefinite-length rejection. 63/63 checks pass including byte-level wire equality for all scalar types. Run `interop_go/main.go` to verify against your build.

Should interoperate with any RFC 8949-compliant decoder; the official RFC 8949 Appendix A test vectors are included in `test-vectors/` and run as part of `rake test`.

---

## Further Reading

The wiki covers what isn't part of the everyday API:

- [`wiki/Internals`](../../wiki/Internals) — float-encoding algorithm, sharedref bookkeeping, lazy architecture, fast wire format, depth tracking, RFC 8949 compliance breakdown, determinism guarantees, performance benchmarks and tuning.

---

## License

Apache License 2.0. See [LICENSE](LICENSE).

Issues, PRs, and bug reports welcome.
