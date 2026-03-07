# mruby-cbor

A fast, spec-compliant [CBOR](https://cbor.io) (RFC 8949) implementation for [mruby](https://github.com/mruby/mruby).

## Features

- Full encode/decode for integers, floats, strings, byte strings, arrays, maps, booleans, nil
- BigInt support (tags 2/3) when compiled with `MRB_USE_BIGINT`
- Float16/32/64 decode including subnormals, Inf and NaN
- Shared references (tags 28/29) including cyclic structures, in both eager and lazy decoder
- `CBOR::Lazy` for zero-copy, on-demand decoding of nested structures
- `CBOR.stream` for zero-copy streaming of CBOR sequences via mmap
- ~30% faster than msgpack on typical workloads
- `CBOR::Lazy` is ~1.3-3x faster than simdjson on-demand depending on the workload. We are spending more time in the mruby vm, but simdjson takes up to ~3 times longer to iterate through a document and get its values.

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

`decode_lazy` returns a `CBOR::Lazy` object that wraps the raw buffer without decoding anything.
Use `[]` or `dig` to navigate and `.value` to materialise the value at the point you actually need it.

```ruby
lazy = CBOR.decode_lazy(big_payload)

# [] is O(n) in the number of keys/elements skipped, not the full document
status = lazy["statuses"][0]["text"].value

# dig is equivalent but more concise
status = lazy.dig("statuses", 0, "text").value

# [] raises on missing key/index; dig propagates nil
lazy["missing"]          # => KeyError
lazy.dig("missing", "x") # => nil
```

Results are cached — repeated access to the same key or index is O(1).

### Shared References (Tags 28/29)

Shared references are supported in both the eager decoder and `CBOR::Lazy`, including cyclic structures.

```ruby
# Encode with shared references (deduplicates identical objects by identity)
a = [1, 2, 3]
buf = CBOR.encode({ "x" => a, "y" => a })

# Eager decode preserves identity
h = CBOR.decode(buf)
h["x"].equal?(h["y"])  # => true

# Lazy .value also preserves identity
h = CBOR.decode_lazy(buf).value
h["x"].equal?(h["y"])  # => true

# Cyclic structures
a = []
a << a
buf = CBOR.encode(a)
result = CBOR.decode(buf)
result.equal?(result[0])  # => true
```

### Streaming

`CBOR.stream` reads a file containing a sequence of CBOR documents using mmap and yields each
as a `CBOR::Lazy` object. No copying occurs — the buffer is a zero-copy view of the mapped memory.

```ruby
CBOR.stream("data.cbor") do |lazy|
  puts lazy["id"].value
end
```

## Installation

Add to your `build_config.rb`:

```ruby
conf.gem github: "Asmod4n/mruby-cbor"
```

## License

Apache-2.0