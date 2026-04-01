JSON.zero_copy_parsing = true
json = File.read('twitter.json')
data = JSON.parse json
cbor = CBOR.encode(data)
cbor_fast = CBOR.encode_fast(data)
msgpack = MessagePack.pack(data)

pointer = "/search_metadata"

puts "=" * 100
puts "EAGER DECODE BENCHMARK (twitter.json)"
puts "=" * 100

# CBOR Fast
puts "\nCBOR.decode_fast"
timer = Chrono::Timer.new
result = CBOR.decode_fast(cbor_fast)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"

# CBOR Normal
puts "\nCBOR.decode"
timer = Chrono::Timer.new
result = CBOR.decode(cbor)
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
json = File.read('twitter.json')
# JSON
puts "\nJSON.parse"
timer = Chrono::Timer.new
result = JSON.parse(json)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"


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
puts "ENCODE BENCHMARK (twitter.json → Ruby → encoded)"
puts "=" * 100

# CBOR Fast
puts "\nCBOR.encode_fast"
timer = Chrono::Timer.new
cbor_fast = CBOR.encode_fast(data)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"
puts "  Size: #{cbor_fast.bytesize} bytes"

# CBOR Normal (canonical)
puts "\nCBOR.encode"
timer = Chrono::Timer.new
cbor_normal = CBOR.encode(data)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"
puts "  Size: #{cbor_normal.bytesize} bytes"

# MessagePack
puts "\nMessagePack.pack"
timer = Chrono::Timer.new
msgpack2 = MessagePack.pack(data)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"
puts "  Size: #{msgpack2.bytesize} bytes"

# JSON
puts "\nJSON.dump"
timer = Chrono::Timer.new
json2 = JSON.dump(data)
elapsed = timer.elapsed
ops = (1.0 / elapsed).round(2)
puts "  Time: #{elapsed.round(9)} sec"
puts "  OPS:  #{ops}"
puts "  Size: #{json2.bytesize} bytes"

puts "\n" + "=" * 100
puts "Wire Sizes (original vs re-encoded):"
puts "  CBOR (orig fast):    #{cbor.bytesize} bytes"
puts "  CBOR (new fast):     #{cbor_fast.bytesize} bytes"
puts "  CBOR (new normal):   #{cbor_normal.bytesize} bytes"
puts "  MessagePack:         #{msgpack2.bytesize} bytes"
puts "  JSON:                #{json2.bytesize} bytes"
puts "=" * 100
