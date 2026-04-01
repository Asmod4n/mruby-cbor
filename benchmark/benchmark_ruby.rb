require "json"
require "benchmark"

json = File.read("twitter.json")


# Parse once (same as your CBOR/MessagePack benchmark)
pointer_key = "search_metadata"

puts "=" * 100
puts "EAGER DECODE BENCHMARK (twitter.json)"
puts "=" * 100

# JSON.parse (MRI only)
time = Benchmark.measure { JSON.parse(json) }.real
ops  = (1.0 / time).round(2)


puts "\nJSON.parse"
puts "  Time: #{time.round(9)} sec"
puts "  OPS:  #{ops}"

puts "\n" + "=" * 100
puts "LAZY DECODE BENCHMARK — /#{pointer_key}"
puts "=" * 100
json = File.read("twitter.json")
# MRI has no lazy mode → simulate same work: full parse + lookup
obj = nil
time = Benchmark.measure {
  obj = JSON.parse(json)[pointer_key]
}.real
ops = (1.0 / time).round(2)


puts "\nJSON.parse + lookup"
puts "  Result: #{obj.inspect}"
puts "  Time:   #{time.round(9)} sec"
puts "  OPS:    #{ops}"
puts "  Note: MRI JSON has no lazy mode; full parse required."
json = File.read("twitter.json")
puts "\n" + "=" * 100
puts "ENCODE BENCHMARK (twitter.json → Ruby → encoded)"
puts "=" * 100
data = JSON.parse(json)


# JSON.dump
time = Benchmark.measure { JSON.dump(data) }.real

json = File.read("twitter.json")
data = JSON.parse(json)
ops  = (1.0 / time).round(2)
json_dump = JSON.dump(data)


puts "\nJSON.dump"
puts "  Time: #{time.round(9)} sec"
puts "  OPS:  #{ops}"
puts "  Size: #{json_dump.bytesize} bytes"
json = File.read("twitter.json")
data = JSON.parse(json)
# JSON.generate
time = Benchmark.measure { JSON.generate(data) }.real


ops  = (1.0 / time).round(2)
json_gen = JSON.generate(data)


puts "\nJSON.generate"
puts "  Time: #{time.round(9)} sec"
puts "  OPS:  #{ops}"
puts "  Size: #{json_gen.bytesize} bytes"

puts "\n" + "=" * 100
puts "Wire Sizes (original vs re-encoded):"
puts "  JSON (original): #{json.bytesize} bytes"
puts "  JSON.dump:       #{json_dump.bytesize} bytes"
puts "  JSON.generate:   #{json_gen.bytesize} bytes"
puts "=" * 100
