JSON.zero_copy_parsing = true
json = File.read('twitter.json')
data = JSON.parse json
cbor = CBOR.encode(data)
cbor_size = cbor.bytesize
msgpack = MessagePack.pack(data)
msgpack_size = msgpack.bytesize
json_size = json.bytesize

pointer = "/statuses/50/retweeted_status/user/screen_name"

puts "=" * 100
puts "EAGER DECODE BENCHMARK (twitter.json)"
puts "=" * 100
GC.start
# CBOR
puts "\nCBOR.decode"
timer = Chrono::Timer.new
result = CBOR.decode(cbor)
elapsed = timer.elapsed

puts "  Time: #{elapsed.round(9)} sec"
puts "  Throughput: #{(cbor_size.to_f / elapsed / 1_000_000_000).round(2)} GBps"

# MessagePack
puts "\nMessagePack.unpack"
timer = Chrono::Timer.new
result = MessagePack.unpack(msgpack)
elapsed = timer.elapsed

puts "  Time: #{elapsed.round(9)} sec"
puts "  Throughput: #{(msgpack_size.to_f / elapsed / 1_000_000_000).round(2)} GBps"

# JSON
puts "\nJSON.parse"
timer = Chrono::Timer.new
result = JSON.parse(json)
elapsed = timer.elapsed

puts "  Time: #{elapsed.round(9)} sec"
puts "  Throughput: #{(json_size.to_f / elapsed / 1_000_000_000).round(2)} GBps"

puts "\n" + "=" * 100
puts "LAZY DECODE BENCHMARK — #{pointer}"
puts "=" * 100
GC.start
# CBOR Lazy
puts "\nCBOR.decode_lazy"
timer = Chrono::Timer.new
result = CBOR.decode_lazy(cbor)["statuses"][50]["retweeted_status"]["user"]["screen_name"].value
elapsed = timer.elapsed

puts "  Result: #{result.inspect}"
puts "  Time: #{elapsed.round(9)} sec"
puts "  Throughput: #{(cbor_size.to_f / elapsed / 1_000_000_000).round(2)} GBps"

# MessagePack Lazy
puts "\nMessagePack.unpack_lazy"
timer = Chrono::Timer.new
result = MessagePack.unpack_lazy(msgpack).at_pointer(pointer)
elapsed = timer.elapsed

puts "  Result: #{result.inspect}"
puts "  Time: #{elapsed.round(9)} sec"
puts "  Throughput: #{(msgpack_size.to_f / elapsed / 1_000_000_000).round(2)} GBps"

# JSON Lazy
puts "\nJSON.parse_lazy"
timer = Chrono::Timer.new
result = JSON.parse_lazy(json).at_pointer(pointer)
elapsed = timer.elapsed

puts "  Result: #{result.inspect}"
puts "  Time: #{elapsed.round(9)} sec"
puts "  Throughput: #{(json_size.to_f / elapsed / 1_000_000_000).round(2)} GBps"

puts "\n" + "=" * 100
puts "Wire Sizes:"
puts "  CBOR:        #{cbor_size} bytes"
puts "  MessagePack: #{msgpack_size} bytes"
puts "  JSON:        #{json_size} bytes"
puts "=" * 100
