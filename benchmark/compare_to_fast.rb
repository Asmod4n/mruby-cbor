# CBOR encode/decode benchmark — canonical vs fast path
#
# Run with:
#   ./mruby/bin/mruby benchmark_cbor.rb

ITERATIONS = 100_000

# ── Test data ─────────────────────────────────────────────────────────────────

# Small flat map — typical actor message
SMALL_MAP = {
  "id"     => 42,
  "name"   => "Alice",
  "score"  => -99,
  "active" => true
}

# Nested structure
NESTED = {
  "users" => [
    { "id" => 1, "name" => "Alice", "age" => 30 },
    { "id" => 2, "name" => "Bob",   "age" => 25 },
    { "id" => 3, "name" => "Carol", "age" => 35 }
  ],
  "count" => 3
}

# Array of integers — worst case for canonical (each int picks shortest form)
INT_ARRAY = (1..100).to_a

# Pre-encode buffers for decode benchmarks
SMALL_MAP_CANONICAL  = CBOR.encode(SMALL_MAP)
SMALL_MAP_FAST       = CBOR.encode_fast(SMALL_MAP)
NESTED_CANONICAL     = CBOR.encode(NESTED)
NESTED_FAST          = CBOR.encode_fast(NESTED)
INT_ARRAY_CANONICAL  = CBOR.encode(INT_ARRAY)
INT_ARRAY_FAST       = CBOR.encode_fast(INT_ARRAY)

puts "Wire sizes (canonical vs fast):"
puts "  small_map : #{SMALL_MAP_CANONICAL.bytesize} vs #{SMALL_MAP_FAST.bytesize} bytes"
puts "  nested    : #{NESTED_CANONICAL.bytesize} vs #{NESTED_FAST.bytesize} bytes"
puts "  int_array : #{INT_ARRAY_CANONICAL.bytesize} vs #{INT_ARRAY_FAST.bytesize} bytes"

def noop_ruby(a, b, c)
  # intentionally empty
end

# ── Benchmarks ────────────────────────────────────────────────────────────────
GC.start
Benchmark.bmbm(40) do |x|

  x.report("encode canonical  small_map") do
    ITERATIONS.times { CBOR.encode(SMALL_MAP) }
  end

  x.report("encode fast       small_map") do
    ITERATIONS.times { CBOR.encode_fast(SMALL_MAP) }
  end

  x.report("encode canonical  nested") do
    ITERATIONS.times { CBOR.encode(NESTED) }
  end

  x.report("encode fast       nested") do
    ITERATIONS.times { CBOR.encode_fast(NESTED) }
  end

  x.report("encode canonical  int_array[100]") do
    ITERATIONS.times { CBOR.encode(INT_ARRAY) }
  end

  x.report("encode fast       int_array[100]") do
    ITERATIONS.times { CBOR.encode_fast(INT_ARRAY) }
  end


  x.report("decode canonical  small_map") do
    ITERATIONS.times { CBOR.decode(SMALL_MAP_CANONICAL) }
  end

  x.report("decode fast       small_map") do
    ITERATIONS.times { CBOR.decode_fast(SMALL_MAP_FAST) }
  end

  x.report("decode canonical  nested") do
    ITERATIONS.times { CBOR.decode(NESTED_CANONICAL) }
  end

  x.report("decode fast       nested") do
    ITERATIONS.times { CBOR.decode_fast(NESTED_FAST) }
  end

  x.report("decode canonical  int_array[100]") do
    ITERATIONS.times { CBOR.decode(INT_ARRAY_CANONICAL) }
  end

  x.report("decode fast       int_array[100]") do
    ITERATIONS.times { CBOR.decode_fast(INT_ARRAY_FAST) }
  end
  x.report("ruby method call (3 args)") do
    ITERATIONS.times { noop_ruby(1, 2, 3) }
  end

  x.report("ruby block call") do
    ITERATIONS.times { yield if false }  # block dispatch without execution
  end

  if Kernel.respond_to?(:noop_c)
    x.report("C function call (3 args)") do
      ITERATIONS.times { noop_c(1, 2, 3) }
    end
  end
end

# ── Roundtrip correctness check ───────────────────────────────────────────────

puts
puts "Correctness check:"

rt_small = CBOR.decode_fast(CBOR.encode_fast(SMALL_MAP))
puts "  small_map roundtrip: #{rt_small == SMALL_MAP ? 'OK' : 'FAIL'}"

rt_nested = CBOR.decode_fast(CBOR.encode_fast(NESTED))
puts "  nested    roundtrip: #{rt_nested == NESTED ? 'OK' : 'FAIL'}"

rt_ints = CBOR.decode_fast(CBOR.encode_fast(INT_ARRAY))
puts "  int_array roundtrip: #{rt_ints == INT_ARRAY ? 'OK' : 'FAIL'}"

# Negative integers
neg = [-1, -42, -1000, 0, 1, 42, 1000]
rt_neg = CBOR.decode_fast(CBOR.encode_fast(neg))
puts "  negatives roundtrip: #{rt_neg == neg ? 'OK' : 'FAIL'}"

puts "Done."
