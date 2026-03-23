nested_hash = {"hello" => {"foo" => {"bar" => [1,{"my" => "ass"},5]}}}
CBOR.encode(nested_hash)
lazy = CBOR.decode_lazy(CBOR.encode(nested_hash))
puts lazy["hello"]["foo"]["bar"][1]["my"].value

