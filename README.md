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
buf = CBOR.encode({ "x" => a, "y" => a }, sharedrefs: true)

# Eager decode preserves identity
h = CBOR.decode(buf)
h["x"].equal?(h["y"])  # => true

# Lazy .value also preserves identity
h = CBOR.decode_lazy(buf).value
h["x"].equal?(h["y"])  # => true

# Cyclic structures
a = []
a << a
buf = CBOR.encode(a, sharedrefs: true)
result = CBOR.decode(buf)
result.equal?(result[0])  # => true
```


### Registering Tags

CBOR allows you to tagged your encoded values, we expose a smart API to let you handle registering of your own classes

```ruby
class Foo
  attr_accessor :foo, :symbiote
  native_ext_deserialize :@foo, CBOR::Type::String
  native_ext_deserialize :@symbiote, CBOR::Type::Tagged

  def from_allocate
    puts "@foo is #{@foo} and done!"
    self
  end
end

foo = Foo.new
foo.foo = "hallo"
foo.symbiote = :main
CBOR.register_tag(5000, Foo)
bla = CBOR.encode(foo)

foo2 = CBOR.decode bla
puts foo2.inspect
```

We allocate your class without calling initialize, when you define a from_allocate instance method we call that so you can do your own thing here.

### Ruby Symbol handling

You can either build your own class which accepts a `CBOR::Type::ByteString` (or `Type::String`) or you can call CBOR.symbols_as_uint32 to encode symbols are uint32 values.
Encoding Symbols as uint32 values is only safe when sending it to the same mruby executable or libmruby.a

## Installation

Add to your `build_config.rb`:

```ruby
conf.gem github: "Asmod4n/mruby-cbor"
```

## License

Apache-2.0