JSON.zero_copy_parsing = true
json = File.read('twitter.json')
data = JSON.parse json
cbor = CBOR.encode_fast(data)
msgpack = MessagePack.pack(data)

pointer = "/search_metadata"

puts "=" * 100
puts "EAGER DECODE BENCHMARK (twitter.json)"
puts "=" * 100

# CBOR
puts "\nCBOR.decode_fast"
timer = Chrono::Timer.new
result = CBOR.decode_fast(cbor)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"

# MessagePack
puts "\nMessagePack.unpack"
timer = Chrono::Timer.new
result = MessagePack.unpack(msgpack)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"

# JSON
puts "\nJSON.parse"
timer = Chrono::Timer.new
result = JSON.parse(json)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"

puts "\n" + "=" * 100
puts "LAZY DECODE BENCHMARK — #{pointer}"
puts "=" * 100

# CBOR Lazy
puts "\nCBOR.decode_lazy"
timer = Chrono::Timer.new
result = CBOR.decode_lazy(cbor)["search_metadata"].value
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Result: #{result.inspect}"
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"

# MessagePack Lazy
puts "\nMessagePack.unpack_lazy"
timer = Chrono::Timer.new
result = MessagePack.unpack_lazy(msgpack).at_pointer(pointer)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Result: #{result.inspect}"
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"

# JSON Lazy
puts "\nJSON.parse_lazy"
timer = Chrono::Timer.new
result = JSON.parse_lazy(json).at_pointer(pointer)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Result: #{result.inspect}"
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"

puts "\n" + "=" * 100
puts "Wire Sizes:"
puts "  CBOR:        #{cbor.bytesize} bytes"
puts "  MessagePack: #{msgpack.bytesize} bytes"
puts "  JSON:        #{json.bytesize} bytes"
puts "=" * 100
