# mruby-cbor

A fast, spec-compliant [CBOR](https://cbor.io) (RFC 8949) implementation for [mruby](https://github.com/mruby/mruby).

## Features

- Full encode/decode for integers, floats, strings, byte strings, arrays, maps, booleans, nil
- BigInt support (tags 2/3) when compiled with `MRB_USE_BIGINT`
- Float16/32/64 decode including subnormals, Inf and NaN
- Shared references (tags 28/29) including cyclic structures
- `CBOR::Lazy` for zero-copy, on-demand decoding of nested structures
- ~30% faster than msgpack on typical workloads
- `CBOR::Lazy` is ~1.4-3.5x faster than simdjson on-demand parsing on real-world data

## Anti Features

- no support for indefinite-length items

## Usage

```ruby
# Encode
buf = CBOR.encode({ "hello" => [1, 2, 3], "ok" => true })

# Decode
obj = CBOR.decode(buf)

# Lazy decode – only parses what you access
lazy = CBOR.decode_lazy(buf)
lazy["hello"][1].value  # => 2
```

### CBOR::Lazy

`decode_lazy` returns a `CBOR::Lazy` object that wraps the raw buffer without decoding anything. Use `[]` to navigate and `.value` to decode at the point you actually need the data.

```ruby
lazy = CBOR.decode_lazy(big_payload)

# [] is O(n) in the number of keys/elements skipped, not the full document
status = lazy["statuses"][0]["text"].value
```

Results are cached – repeated access to the same key or index is O(1).

### Shared References

Tag 28/29 shared references are supported in both the eager decoder and `CBOR::Lazy`. Cyclic structures are handled correctly.

```ruby
# Decode a stream where two keys point to the same object
h = CBOR.decode(buf_with_shared_refs)
h["a"].equal?(h["b"])  # => true
```

## Benchmarks

Navigating `$.statuses[50].user.id` on `twitter.json` (617 KB), 25,000 iterations, compared against [mruby-fast-json](https://github.com/Asmod4n/mruby-fast-json) (simdjson on-demand):

```
               user     system      total        real
lazy       1.043505   0.001357   1.044862 (  1.149626)
json lazy  2.261862   0.000088   2.261950 (  2.388596)
```

`CBOR::Lazy` is **2.3x faster** than simdjson on-demand for selective field access. This is possible because CBOR is a binary format — no UTF-8 validation, no string unescaping, no number parsing overhead on the skip path.

## Installation

Add to your `build_config.rb`:

```ruby
conf.gem github: "Asmod4n/mruby-cbor"
```

## License

Apache-2.0