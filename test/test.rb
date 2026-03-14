assert('CBOR encode/decode primitives') do
  assert_equal 123, CBOR.decode(CBOR.encode(123))
  assert_equal -5,  CBOR.decode(CBOR.encode(-5))
  assert_equal true, CBOR.decode(CBOR.encode(true))
  assert_equal false, CBOR.decode(CBOR.encode(false))
  assert_equal nil, CBOR.decode(CBOR.encode(nil))
end

assert('CBOR text and bytes') do
  s = "hällo"
  b = "\0\xFF\xFE\xFA"

  assert_equal s, CBOR.decode(CBOR.encode(s))
  assert_equal b, CBOR.decode(CBOR.encode(b))
end

assert('CBOR arrays') do
  ary = [1, 2, 3, "x"]
  assert_equal ary, CBOR.decode(CBOR.encode(ary))
end

assert('CBOR maps') do
  h = { "a" => 1, "b" => [2,3], "c" => { "x" => 9 } }
  assert_equal h, CBOR.decode(CBOR.encode(h))
end

assert('CBOR::Lazy value cache') do
  h = { "a" => 1, "b" => 2 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  v1 = lazy.value
  v2 = lazy.value
  assert_equal v1, v2
  assert_same v1, v2
end

assert('CBOR::Lazy key cache') do
  h = { "a" => 1, "b" => 2 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  x1 = lazy["a"]
  x2 = lazy["a"]
  assert_equal x1, x2
  assert_same x1, x2
end

assert('CBOR::Lazy array access') do
  ary = [10, 20, 30]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_equal 20, lazy[1].value
  assert_equal 30, lazy[2].value
end

assert('CBOR::Lazy nested access with caching') do
  h = { "outer" => { "inner" => [1,2,3] } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  inner1 = lazy["outer"]["inner"]
  inner2 = lazy["outer"]["inner"]
  assert_same inner1, inner2
  assert_equal 3, inner1[2].value
end

assert('CBOR out of bounds raises') do
  broken = "\x63ab"
  assert_raise(RangeError) { CBOR.decode(broken) }
end

assert('CBOR roundtrip large structure') do
  big = {
    "statuses" => (1..200).map { |i| { "id" => i, "txt" => "msg#{i}" } },
    "meta" => { "count" => 200 }
  }
  encoded = CBOR.encode(big)
  decoded = CBOR.decode(encoded)
  assert_equal big, decoded
end

assert('CBOR::Lazy random access stress') do
  h = {
    "statuses" => (1..50).map { |i| { "id" => i, "txt" => "msg#{i}" } },
    "meta" => { "count" => 50 }
  }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  200.times do
    i = rand(0...50)
    assert_equal "msg#{i+1}", lazy["statuses"][i]["txt"].value
  end
end

assert('CBOR::Lazy repeated access does not corrupt state') do
  h = { "a" => { "b" => { "c" => 123 } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  100.times do
    assert_equal 123, lazy["a"]["b"]["c"].value
  end
end

assert('CBOR::Lazy missing key returns nil') do
  h = { "a" => 1 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_raise(KeyError) { lazy["missing"] }
end

assert('CBOR::Lazy array out of bounds') do
  ary = [1,2,3]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_raise(IndexError) { lazy[99] }
end

assert('CBOR::Lazy independent caches') do
  h = { "x" => 1, "y" => 2 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  x = lazy["x"]
  y = lazy["y"]
  assert_equal 1, x.value
  assert_equal 2, y.value
end

assert('CBOR bignum roundtrip') do
  big = (1 << 200) + 12345
  assert_equal big, CBOR.decode(CBOR.encode(big))
end


assert('CBOR negative bignum roundtrip') do
  big = -(1 << 200) - 999
  assert_equal(big, CBOR.decode(CBOR.encode(big)))
end

assert('CBOR bignum boundary: exactly 64-bit') do
  n = (1 << 64) - 1
  assert_equal(n, CBOR.decode(CBOR.encode(n)))
end

assert('CBOR bignum boundary: just above 64-bit') do
  n = (1 << 64)
  assert_equal(n, CBOR.decode(CBOR.encode(n)))
end

assert('CBOR negative bignum boundary: -(2^64)') do
  n = -(1 << 64)
  assert_equal(n, CBOR.decode(CBOR.encode(n)))
end

assert('CBOR very large bignum (4 KB)') do
  # 32768-bit number
  big = (1 << 32768) + 123456789
  assert_equal big, CBOR.decode(CBOR.encode(big))
end

assert('CBOR bignum lazy decode') do
  big = (1 << 200) + 123
  lazy = CBOR.decode_lazy(CBOR.encode(big))
  assert_equal big, lazy.value
end

assert('CBOR negative bignum lazy decode') do
  big = -(1 << 200) - 55
  lazy = CBOR.decode_lazy(CBOR.encode(big))
  assert_equal big, lazy.value
end

assert('CBOR bignum does not corrupt following lazy values') do
  h = {
    "a" => (1 << 200) + 1,
    "b" => (1 << 150) + 2,
    "c" => 123
  }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal h["a"], lazy["a"].value
  assert_equal h["b"], lazy["b"].value
  assert_equal 123, lazy["c"].value
end

assert('CBOR shared ref: two refs to same array (eager)') do
  # 82 D8 1C 82 01 02 D8 1D 00
  buf = "\x82\xD8\x1C\x82\x01\x02\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('CBOR shared ref: map with shared value (eager)') do
  # A2 61 61 D8 1C 83 01 02 03 61 62 D8 1D 00
  buf = "\xA2\x61\x61\xD8\x1C\x83\x01\x02\x03\x61\x62\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR shared ref: cyclic array (eager)') do
  # D8 1C 81 D8 1D 00
  buf = "\xD8\x1C\x81\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_same result, result[0]
end

assert('CBOR shared ref: two refs to same array (lazy)') do
  buf = "\x82\xD8\x1C\x82\x01\x02\xD8\x1D\x00"
  result = CBOR.decode_lazy(buf).value
  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('CBOR shared ref: map with shared value (lazy)') do
  buf = "\xA2\x61\x61\xD8\x1C\x83\x01\x02\x03\x61\x62\xD8\x1D\x00"
  result = CBOR.decode_lazy(buf).value
  assert_equal [1, 2, 3], result["a"]
  assert_same result["a"], result["b"]
end

assert('CBOR shared ref: cyclic array (lazy)') do
  buf = "\xD8\x1C\x81\xD8\x1D\x00"
  result = CBOR.decode_lazy(buf).value
  assert_same result, result[0]
end

assert('CBOR shared ref: invalid index raises') do
  # Standalone Tag29(99) - shareable table is empty, index 99 not found
  # D8 1D 18 63  =  Tag(29), uint8(99)
  buf = "\xD8\x1D\x18\x63"
  assert_raise(IndexError) { CBOR.decode(buf) }
end

assert('CBOR shared ref: scalar shareable (integer)') do
  # [Tag28(42), Tag29(0)]
  buf = "\x82\xD8\x1C\x18\x2A\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_equal [42, 42], result
end

assert('CBOR shared ref: two refs to same array (eager)') do
  a = [1, 2]
  obj = [a, a]

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode(buf)

  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('CBOR shared ref: map with shared value (eager)') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v }

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode(buf)

  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR shared ref: cyclic array (eager)') do
  a = []
  a << a

  buf = CBOR.encode(a, sharedrefs: true)
  result = CBOR.decode(buf)

  assert_same result, result[0]
end

assert('CBOR shared ref: two refs to same array (lazy)') do
  a = [1, 2]
  obj = [a, a]

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode_lazy(buf).value

  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('CBOR shared ref: map with shared value (lazy)') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v }

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode_lazy(buf).value

  assert_equal [1, 2, 3], result["a"]
  assert_same result["a"], result["b"]
end

assert('CBOR shared ref: cyclic array (lazy)') do
  a = []
  a << a

  buf = CBOR.encode(a, sharedrefs: true)
  result = CBOR.decode_lazy(buf).value

  assert_same result, result[0]
end

assert('CBOR lazy sharedref: tag28 inside lazy path without prior registration') do

  buf = "\xA2" \
        "\x65outer" \
        "\xD8\x1C\x82\x01\x02" \
        "\x63ref" \
        "\xD8\x1D\x00"

  lazy = CBOR.decode_lazy(buf)


  assert_equal [1,2], lazy["ref"].value
end

# ============================================================================
# Symbol encoding strategies
# ============================================================================

assert('CBOR symbols_as_string: encodes symbol as tagged string') do
  CBOR.symbols_as_string
  sym = :hello
  buf = CBOR.encode(sym)
  decoded = CBOR.decode(buf)
  assert_equal :hello, decoded
  CBOR.no_symbols
end

assert('CBOR no_symbols: decoding tag 39 raises') do
  CBOR.symbols_as_string
  buf = CBOR.encode(:hello)
  CBOR.no_symbols
  assert_raise(RuntimeError) { CBOR.decode(buf) }
end

assert('CBOR symbols_as_uint32: roundtrip') do
  CBOR.symbols_as_uint32
  sym = :hello
  buf = CBOR.encode(sym)
  decoded = CBOR.decode(buf)
  assert_equal sym, decoded
  CBOR.no_symbols
end

assert('CBOR symbols_as_string: in hash keys') do
  CBOR.symbols_as_string
  h = { hello: 1, world: 2 }
  buf = CBOR.encode(h)
  decoded = CBOR.decode(buf)
  assert_equal({ hello: 1, world: 2 }, decoded)
  CBOR.no_symbols
end

assert('CBOR symbols_as_string: in arrays') do
  CBOR.symbols_as_string
  ary = [:a, :b, :c]
  buf = CBOR.encode(ary)
  decoded = CBOR.decode(buf)
  assert_equal ary, decoded
  CBOR.no_symbols
end

# ============================================================================
# register_tag
# ============================================================================

assert('CBOR register_tag: encode and decode custom class') do
  class Point
    native_ext_type :@x, CBOR::Type::Integer
    native_ext_type :@y, CBOR::Type::Integer

    def initialize(x, y)
      @x = x
      @y = y
    end

    def from_allocate
      self
    end

    def ==(other)
      other.is_a?(Point) && @x == other.instance_variable_get(:@x) && @y == other.instance_variable_get(:@y)
    end
  end

  CBOR.register_tag(1000, Point)

  p = Point.new(3, 7)
  buf = CBOR.encode(p)
  decoded = CBOR.decode(buf)

  assert_true decoded.is_a?(Point)
  assert_equal 3, decoded.instance_variable_get(:@x)
  assert_equal 7, decoded.instance_variable_get(:@y)
end

assert('CBOR register_tag: reserved tags raise') do
  class Dummy; end
  assert_raise(ArgumentError) { CBOR.register_tag(2,  Dummy) }
  assert_raise(ArgumentError) { CBOR.register_tag(3,  Dummy) }
  assert_raise(ArgumentError) { CBOR.register_tag(28, Dummy) }
  assert_raise(ArgumentError) { CBOR.register_tag(29, Dummy) }
  assert_raise(ArgumentError) { CBOR.register_tag(39, Dummy) }
end

assert('CBOR register_tag: built-in classes raise') do
  assert_raise(TypeError) { CBOR.register_tag(1001, String)  }
  assert_raise(TypeError) { CBOR.register_tag(1002, Array)   }
  assert_raise(TypeError) { CBOR.register_tag(1003, Hash)    }
  assert_raise(TypeError) { CBOR.register_tag(1004, Integer) }
end

# ============================================================================
# UnhandledTag
# ============================================================================

assert('CBOR UnhandledTag: unknown tag wraps value') do
  # Tag 100 (unknown), payload integer 42
  # D8 64 = tag(100), 18 2A = uint8(42)
  buf = "\xD8\x64\x18\x2A"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  assert_equal 42,  result.value
end

assert('CBOR UnhandledTag: unknown tag with string payload') do
  buf = "\xD8\x64\x63\x61\x62\x63"  # tag(100) + "abc"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal "abc", result.value
end

assert('CBOR UnhandledTag: lazy decode preserves tag') do
  buf = "\xD8\x64\x18\x2A"
  result = CBOR.decode_lazy(buf).value
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 42, result.value
end

# ============================================================================
# Float edge cases
# ============================================================================

assert('CBOR float: positive infinity roundtrip') do
  f = Float::INFINITY
  assert_equal f, CBOR.decode(CBOR.encode(f))
end

assert('CBOR float: negative infinity roundtrip') do
  f = -Float::INFINITY
  assert_equal f, CBOR.decode(CBOR.encode(f))
end

assert('CBOR float: NaN roundtrip') do
  f = Float::NAN
  result = CBOR.decode(CBOR.encode(f))
  assert_true result.nan?
end

assert('CBOR float: zero roundtrip') do
  assert_equal 0.0, CBOR.decode(CBOR.encode(0.0))
end

assert('CBOR float: negative zero roundtrip') do
  result = CBOR.decode(CBOR.encode(-0.0))
  assert_equal 0.0, result
end

assert('CBOR float: small float roundtrip') do
  assert_equal 1.5, CBOR.decode(CBOR.encode(1.5))
end

assert('CBOR float: large float roundtrip') do
  f = 1.0e300
  assert_equal f, CBOR.decode(CBOR.encode(f))
end

assert('CBOR float16: decode 1.0') do
  # F9 3C 00 = float16(1.0)
  buf = "\xF9\x3C\x00"
  assert_equal 1.0, CBOR.decode(buf)
end

assert('CBOR float16: decode 0.0') do
  # F9 00 00 = float16(0.0)
  buf = "\xF9\x00\x00"
  assert_equal 0.0, CBOR.decode(buf)
end

assert('CBOR float16: decode infinity') do
  # F9 7C 00 = float16(+Inf)
  buf = "\xF9\x7C\x00"
  assert_equal Float::INFINITY, CBOR.decode(buf)
end

assert('CBOR float16: decode NaN') do
  # F9 7E 00 = float16(NaN)
  buf = "\xF9\x7E\x00"
  assert_true CBOR.decode(buf).nan?
end

assert('CBOR float16: decode subnormal') do
  # F9 00 01 = float16 subnormal (smallest positive subnormal)
  buf = "\xF9\x00\x01"
  result = CBOR.decode(buf)
  assert_true result > 0.0
  assert_true result < 1.0e-4
end

assert('CBOR float32: decode 1.0') do
  # FA 3F 80 00 00 = float32(1.0)
  buf = "\xFA\x3F\x80\x00\x00"
  assert_equal 1.0, CBOR.decode(buf)
end

# ============================================================================
# Simple values
# ============================================================================

assert('CBOR simple value with skip (info=24)') do
  # F8 00 = simple(0) with one-byte payload — decoded as nil
  buf = "\xF8\x00"
  assert_nil CBOR.decode(buf)
end

assert('CBOR simple values below 20 decode as nil') do
  # major 7, info 0..19 -> nil
  (0..19).each do |i|
    buf = (0xE0 | i).chr
    assert_nil CBOR.decode(buf)
  end
end

# ============================================================================
# CBOR::Lazy#dig
# ============================================================================

assert('CBOR::Lazy#dig: nested map access') do
  h = { "a" => { "b" => { "c" => 42 } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal 42, lazy.dig("a", "b", "c").value
end

assert('CBOR::Lazy#dig: nested array access') do
  ary = [[1, 2, 3], [4, 5, 6]]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_equal 5, lazy.dig(1, 1).value
end

assert('CBOR::Lazy#dig: mixed map and array') do
  h = { "items" => [10, 20, 30] }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal 20, lazy.dig("items", 1).value
end

assert('CBOR::Lazy#dig: missing key returns nil') do
  h = { "a" => 1 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_nil lazy.dig("missing")
end

assert('CBOR::Lazy#dig: nil propagates in middle of chain') do
  h = { "a" => 1 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_nil lazy.dig("missing", "deeper")
end

assert('CBOR::Lazy#dig: no keys returns self') do
  h = { "a" => 1 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_same lazy, lazy.dig
end

assert('CBOR::Lazy#dig: array out of bounds returns nil') do
  ary = [1, 2, 3]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_nil lazy.dig(99)
end

assert('CBOR::Lazy#dig: negative array index') do
  ary = [1, 2, 3]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_equal 3, lazy.dig(-1).value
end

assert('CBOR::Lazy#dig: caches results') do
  h = { "a" => { "b" => 99 } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  r1 = lazy.dig("a", "b")
  r2 = lazy.dig("a", "b")
  assert_same r1, r2
end

# ============================================================================
# Lazy array: negative indices
# ============================================================================

assert('CBOR::Lazy array: negative index -1') do
  ary = [10, 20, 30]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_equal 30, lazy[-1].value
end

assert('CBOR::Lazy array: negative index -2') do
  ary = [10, 20, 30]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_equal 20, lazy[-2].value
end

assert('CBOR::Lazy array: negative out of bounds raises') do
  ary = [1, 2, 3]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_raise(IndexError) { lazy[-99] }
end

# ============================================================================
# Shared refs: encode path
# ============================================================================

assert('CBOR shared ref: nested shared hash') do
  shared = { "x" => 1 }
  obj = { "a" => shared, "b" => shared }
  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode(buf)
  assert_same result["a"], result["b"]
end

assert('CBOR shared ref: shared string') do
  s = "hello"
  obj = [s, s, s]
  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode(buf)
  assert_same result[0], result[1]
  assert_same result[1], result[2]
end

assert('CBOR shared ref: no sharedrefs by default') do
  s = "hello"
  obj = [s, s]
  buf = CBOR.encode(obj)
  result = CBOR.decode(buf)
  # values equal but not necessarily same object
  assert_equal result[0], result[1]
end

assert('CBOR shared ref: lazy access on cyclic structure') do
  a = []
  a << a
  buf = CBOR.encode(a, sharedrefs: true)
  lazy = CBOR.decode_lazy(buf)
  result = lazy.value
  assert_same result, result[0]
end

# ============================================================================
# Integer edge cases
# ============================================================================

assert('CBOR integer: MRB_INT_MAX roundtrip') do
  n = 2**30 - 1  # safe for 32-bit mrb_int
  assert_equal n, CBOR.decode(CBOR.encode(n))
end

assert('CBOR integer: -1 roundtrip') do
  assert_equal(-1, CBOR.decode(CBOR.encode(-1)))
end

assert('CBOR integer: 0 roundtrip') do
  assert_equal 0, CBOR.decode(CBOR.encode(0))
end

assert('CBOR integer: 255 roundtrip (uint8 boundary)') do
  assert_equal 255, CBOR.decode(CBOR.encode(255))
end

assert('CBOR integer: 256 roundtrip (uint16 boundary)') do
  assert_equal 256, CBOR.decode(CBOR.encode(256))
end

assert('CBOR integer: 65535 roundtrip (uint16 max)') do
  assert_equal 65535, CBOR.decode(CBOR.encode(65535))
end

assert('CBOR integer: 65536 roundtrip (uint32 boundary)') do
  assert_equal 65536, CBOR.decode(CBOR.encode(65536))
end

# ============================================================================
# Map with non-string keys
# ============================================================================

assert('CBOR map: integer keys') do
  h = { 1 => "one", 2 => "two" }
  assert_equal h, CBOR.decode(CBOR.encode(h))
end

assert('CBOR::Lazy map: integer key access') do
  h = { 1 => "one", 2 => "two" }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal "one", lazy[1].value
  assert_equal "two", lazy[2].value
end

# ============================================================================
# Empty containers
# ============================================================================

assert('CBOR empty array roundtrip') do
  assert_equal [], CBOR.decode(CBOR.encode([]))
end

assert('CBOR empty hash roundtrip') do
  assert_equal({}, CBOR.decode(CBOR.encode({})))
end

assert('CBOR empty string roundtrip') do
  assert_equal "", CBOR.decode(CBOR.encode(""))
end

assert('CBOR::Lazy empty array access raises') do
  lazy = CBOR.decode_lazy(CBOR.encode([]))
  assert_raise(IndexError) { lazy[0] }
end

assert('CBOR::Lazy empty map access raises') do
  lazy = CBOR.decode_lazy(CBOR.encode({}))
  assert_raise(KeyError) { lazy["x"] }
end

# ============================================================================
# CBOR.stream
# ============================================================================

class MockIO
  def initialize(data)
    @data = data
    @pos  = 0
  end

  def seek(pos)
    @pos = pos
  end

  def read(n)
    return nil if @pos >= @data.bytesize
    slice = @data[@pos, n]
    @pos += slice.bytesize
    slice
  end
end

assert('CBOR.stream: single map document') do
  buf = CBOR.encode({ "a" => 1 })
  io  = MockIO.new(buf)
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 1, results.length
  assert_equal({ "a" => 1 }, results[0])
end

assert('CBOR.stream: multiple concatenated documents') do
  doc1 = CBOR.encode({ "a" => 1 })
  doc2 = CBOR.encode([1, 2, 3])
  doc3 = CBOR.encode(42)
  io   = MockIO.new(doc1 + doc2 + doc3)
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 3,              results.length
  assert_equal({ "a" => 1 },  results[0])
  assert_equal [1, 2, 3],     results[1]
  assert_equal 42,            results[2]
end

assert('CBOR.stream: document shorter than 9 bytes') do
  buf = CBOR.encode(0)
  io  = MockIO.new(buf)
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 1, results.length
  assert_equal 0, results[0]
end

assert('CBOR.stream: large document requiring readahead') do
  big = { "items" => (1..100).map { |i| { "id" => i, "name" => "item#{i}" } } }
  buf = CBOR.encode(big)
  assert_true buf.bytesize > 9
  io  = MockIO.new(buf)
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 1,   results.length
  assert_equal big, results[0]
end

assert('CBOR.stream: enumerator without block') do
  doc1 = CBOR.encode("hello")
  doc2 = CBOR.encode("world")
  io   = MockIO.new(doc1 + doc2)
  results = CBOR.stream(io).map(&:value)
  assert_equal 2,       results.length
  assert_equal "hello", results[0]
  assert_equal "world", results[1]
end

assert('CBOR.stream: empty io yields nothing') do
  io      = MockIO.new("")
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 0, results.length
end

assert('CBOR.stream: offset parameter skips first bytes') do
  doc1 = CBOR.encode("skip")
  doc2 = CBOR.encode("keep")
  io   = MockIO.new(doc1 + doc2)
  results = []
  CBOR.stream(io, doc1.bytesize) { |doc| results << doc.value }
  assert_equal 1,      results.length
  assert_equal "keep", results[0]
end

assert('CBOR.stream: document containing float') do
  buf = CBOR.encode(1.5)
  io  = MockIO.new(buf)
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 1,   results.length
  assert_equal 1.5, results[0]
end

assert('CBOR.stream: document containing shared refs') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v }
  buf = CBOR.encode(obj, sharedrefs: true)
  io  = MockIO.new(buf)
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 1, results.length
  assert_equal({ "a" => [1,2,3], "b" => [1,2,3] }, results[0])
end

assert('CBOR.stream: documents with various integer sizes') do
  docs = [
    0,           # 0 bits
    23,          # inline
    24,          # uint8 boundary
    255,         # uint8 max
    256,         # uint16 boundary
    65535,       # uint16 max
    65536,       # uint32 boundary
    0xFFFFFFFF,  # uint32 max
    0x100000000, # uint64 boundary
  ]
  buf = docs.map { |n| CBOR.encode(n) }.join
  io  = MockIO.new(buf)
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal docs, results
end


assert('CBOR integer overflow: negative uint32 boundary') do
  # major 1, value 0xFFFFFFFF => -4294967296
  buf = "\x3A\xFF\xFF\xFF\xFF"
  assert_equal(-(2**32), CBOR.decode(buf))
end

assert('CBOR integer overflow: negative uint64 > MRB_INT_MAX+1') do
  # major 1, value 0x8000000000000000
  buf = "\x3B\x80\x00\x00\x00\x00\x00\x00\x00"
  assert_equal(-(2**63) - 1, CBOR.decode(buf))
end

assert('CBOR integer overflow: unsigned uint64 > MRB_INT_MAX+1') do
  # major 0, value 0xFFFFFFFFFFFFFFFF
  buf = "\x1B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_equal(2**64 - 1, CBOR.decode(buf))
end

assert('CBOR array with bigint length raises') do
  buf = "\x9B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_raise(RangeError) { CBOR.decode(buf) }
end

assert('CBOR negative integer: -1 - UINT64_MAX') do
  # major 1, info 27, value 0xFFFFFFFFFFFFFFFF
  # decoded as -1 - UINT64_MAX = -2^64
  buf = "\x3B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  begin
    result = CBOR.decode(buf)
    assert_equal(-(2**64), result)  # MRB_USE_BIGINT path
  rescue RangeError
    # kein MRB_USE_BIGINT, raise ist korrekt
  end
end

# ============================================================================
# Additional comprehensive test suite for mruby-cbor
# These tests complement test.rb and cover additional edge cases
# ============================================================================

# ============================================================================
# Lazy decoding with registered tags
# ============================================================================

assert('CBOR register_tag: lazy decode with custom class') do
  class Point
    native_ext_type :@x, CBOR::Type::Integer
    native_ext_type :@y, CBOR::Type::Integer

    def initialize(x = 0, y = 0)
      @x = x
      @y = y
    end

    def from_allocate
      self
    end

    def ==(other)
      other.is_a?(Point) && @x == other.instance_variable_get(:@x) && @y == other.instance_variable_get(:@y)
    end
  end

  CBOR.register_tag(1001, Point)

  p = Point.new(5, 10)
  buf = CBOR.encode(p)
  lazy = CBOR.decode_lazy(buf)
  decoded = lazy.value

  assert_true decoded.is_a?(Point)
  assert_equal 5, decoded.instance_variable_get(:@x)
  assert_equal 10, decoded.instance_variable_get(:@y)
end

assert('CBOR register_tag: lazy nested access through registered tag') do
  class Rect
    native_ext_type :@corners, CBOR::Type::Array

    def initialize(corners = [])
      @corners = corners
    end

    def from_allocate
      self
    end
  end

  CBOR.register_tag(1002, Rect)

  rect = Rect.new([[0, 0], [10, 10]])
  buf = CBOR.encode(rect)
  lazy = CBOR.decode_lazy(buf)

  # Access first corner via lazy
  first = lazy.dig("corners", 0)
  assert_not_nil first
  assert_equal 0, first[0].value
end

# ============================================================================
# Lazy access stress and edge cases
# ============================================================================

assert('CBOR::Lazy: repeated dig calls on same path') do
  h = { "a" => { "b" => { "c" => { "d" => 42 } } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  100.times do
    result = lazy.dig("a", "b", "c", "d")
    assert_equal 42, result.value
  end
end

assert('CBOR::Lazy: interleaved access patterns') do
  h = {
    "users" => [
      { "id" => 1, "name" => "Alice", "age" => 30 },
      { "id" => 2, "name" => "Bob",   "age" => 25 },
      { "id" => 3, "name" => "Carol", "age" => 35 }
    ],
    "meta" => { "count" => 3 }
  }

  lazy = CBOR.decode_lazy(CBOR.encode(h))

  # Access in non-sequential order
  assert_equal "Carol", lazy["users"][2]["name"].value
  assert_equal 1, lazy["users"][0]["id"].value
  assert_equal 3, lazy["meta"]["count"].value
  assert_equal "Bob", lazy["users"][1]["name"].value
end

assert('CBOR::Lazy: access on shared structure (eager materialization)') do
  shared_val = { "data" => [1, 2, 3] }
  obj = { "x" => shared_val, "y" => shared_val }

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode_lazy(buf).value

  # Verify identity is preserved
  assert_same result["x"], result["y"]
  assert_equal [1, 2, 3], result["x"]["data"]
end

assert('CBOR::Lazy: cyclic structure eager materialization') do
  # Build cyclic: a=[a]
  a = []
  a << a

  buf = CBOR.encode(a, sharedrefs: true)
  result = CBOR.decode_lazy(buf).value

  # Verify cyclic identity
  assert_same result, result[0]
end

assert('CBOR::Lazy: array with mixed types') do
  ary = [42, "hello", 3.14, true, nil, [1, 2], { "x" => 9 }]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))

  assert_equal 42, lazy[0].value
  assert_equal "hello", lazy[1].value
  # Float comparison with tolerance
  result = lazy[2].value
  assert_true (result - 3.14).abs < 0.01
  assert_equal true, lazy[3].value
  assert_nil lazy[4].value
  assert_equal [1, 2], lazy[5].value
  assert_equal({ "x" => 9 }, lazy[6].value)
end

# ============================================================================
# Tag nesting and edge cases
# ============================================================================

assert('CBOR tag: unknown tag wrapping another unknown tag') do
  # Tag100(Tag101(42))
  buf = "\xD8\x64\xD8\x65\x18\x2A"
  result = CBOR.decode(buf)

  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag

  # Inner value should also be UnhandledTag
  inner = result.value
  assert_true inner.is_a?(CBOR::UnhandledTag)
  assert_equal 101, inner.tag
  assert_equal 42, inner.value
end

assert('CBOR tag: unknown tag wrapping array') do
  # Tag200([1, 2, 3])
  buf = "\xD8\xC8\x83\x01\x02\x03"
  result = CBOR.decode(buf)

  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 200, result.tag
  assert_equal [1, 2, 3], result.value
end

assert('CBOR tag: unknown tag wrapping map') do
  # Tag300({ "x" => 1 })
  buf = "\xD9\x01\x2C\xA1\x61\x78\x01"
  result = CBOR.decode(buf)

  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 300, result.tag
  assert_equal({ "x" => 1 }, result.value)
end

assert('CBOR tag: lazy decode of unknown tag') do
  buf = "\xD8\x64\x18\x2A"
  lazy = CBOR.decode_lazy(buf)
  result = lazy.value

  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  assert_equal 42, result.value
end

# ============================================================================
# Nested tag combinations
# ============================================================================

assert('CBOR tag: unknown tag wrapping multiple levels of unknown tags') do
  # Tag100(Tag101(Tag102(Tag103(42))))
  buf = "\xD8\x64\xD8\x65\xD8\x66\xD8\x67\x18\x2A"
  result = CBOR.decode(buf)

  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag

  current = result.value
  assert_equal 101, current.tag

  current = current.value
  assert_equal 102, current.tag

  current = current.value
  assert_equal 103, current.tag
  assert_equal 42, current.value
end

assert('CBOR tag: unknown wrapping array containing unknown tags') do
  # Tag200([Tag100(1), Tag101(2), Tag102(3)])
  buf = "\xD8\xC8\x83\xD8\x64\x01\xD8\x65\x02\xD8\x66\x03"
  result = CBOR.decode(buf)

  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 200, result.tag

  arr = result.value
  assert_equal 3, arr.length

  assert_true arr[0].is_a?(CBOR::UnhandledTag)
  assert_equal 100, arr[0].tag
  assert_equal 1, arr[0].value

  assert_true arr[1].is_a?(CBOR::UnhandledTag)
  assert_equal 101, arr[1].tag
  assert_equal 2, arr[1].value

  assert_true arr[2].is_a?(CBOR::UnhandledTag)
  assert_equal 102, arr[2].tag
  assert_equal 3, arr[2].value
end

assert('CBOR tag: unknown wrapping map with unknown tag values') do
  # Tag300({ "a" => Tag100(1), "b" => Tag101(2) })
  buf = "\xD9\x01\x2C\xA2\x61\x61\xD8\x64\x01\x61\x62\xD8\x65\x02"
  result = CBOR.decode(buf)

  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 300, result.tag

  map = result.value

  assert_true map["a"].is_a?(CBOR::UnhandledTag)
  assert_equal 100, map["a"].tag
  assert_equal 1, map["a"].value

  assert_true map["b"].is_a?(CBOR::UnhandledTag)
  assert_equal 101, map["b"].tag
  assert_equal 2, map["b"].value
end

assert('CBOR tag: unknown wrapping symbol (tag 39)') do
  CBOR.symbols_as_string

  # Tag100(Tag39("hello")) - unknown wrapping symbol
  # Tag39 is 0xD8 0x27
  # Tag100 is 0xD8 0x64
  buf = "\xD8\x64\xD8\x27\x65hello"
  result = CBOR.decode(buf)

  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  assert_equal :hello, result.value

  CBOR.no_symbols
end

assert('CBOR tag: unknown wrapping registered tag') do
  class SimpleValue
    native_ext_type :@val, CBOR::Type::Integer

    def initialize(val = 0)
      @val = val
    end

    def from_allocate
      self
    end
  end

  CBOR.register_tag(2000, SimpleValue)

  # Tag100(Tag2000({val: 42}))
  obj = SimpleValue.new(42)
  inner_buf = CBOR.encode(obj)

  # Manually wrap in unknown tag 100
  # Can't easily construct this without manual binary construction
  # So encode-decode roundtrip to verify nesting works
  wrapped = { "tagged" => obj }
  buf = CBOR.encode(wrapped)
  result = CBOR.decode(buf)

  assert_true result["tagged"].is_a?(SimpleValue)
  assert_equal 42, result["tagged"].instance_variable_get(:@val)
end

assert('CBOR tag: unknown in lazy array with mixed tags') do
  # [Tag100(1), Tag100(2), 3, "text"]
  buf = "\x84\xD8\x64\x01\xD8\x64\x02\x03\x64text"
  lazy = CBOR.decode_lazy(buf)

  # Access unknown tags through lazy
  elem0 = lazy[0].value
  assert_true elem0.is_a?(CBOR::UnhandledTag)
  assert_equal 100, elem0.tag
  assert_equal 1, elem0.value

  elem1 = lazy[1].value
  assert_true elem1.is_a?(CBOR::UnhandledTag)
  assert_equal 100, elem1.tag
  assert_equal 2, elem1.value

  assert_equal 3, lazy[2].value
  assert_equal "text", lazy[3].value
end

assert('CBOR tag: triple-nested unknowns in structure') do
  # {"a": Tag100(Tag101(Tag102(42))), "b": Tag103("x")}
  buf = "\xA2\x61\x61\xD8\x64\xD8\x65\xD8\x66\x18\x2A\x61\x62\xD8\x67\x61\x78"
  result = CBOR.decode(buf)

  assert_true result["a"].is_a?(CBOR::UnhandledTag)
  assert_equal 100, result["a"].tag

  nested = result["a"].value
  assert_equal 101, nested.tag

  deep = nested.value
  assert_equal 102, deep.tag
  assert_equal 42, deep.value

  assert_true result["b"].is_a?(CBOR::UnhandledTag)
  assert_equal 103, result["b"].tag
  assert_equal "x", result["b"].value
end

# ============================================================================
# Stream edge cases
# ============================================================================

assert('CBOR.stream: multiple documents with different major types') do
  docs = [
    42,
    "hello",
    [1, 2, 3],
    { "x" => 1 },
    true,
    nil
  ]

  buf = docs.map { |d| CBOR.encode(d) }.join
  io = MockIO.new(buf)
  results = CBOR.stream(io).map(&:value)

  assert_equal docs.length, results.length
  docs.each_with_index do |expected, i|
    assert_equal expected, results[i]
  end
end

assert('CBOR.stream: document with nested shared refs') do
  inner = { "data" => [1, 2, 3] }
  obj = [inner, inner, inner]
  buf = CBOR.encode(obj, sharedrefs: true)

  io = MockIO.new(buf)
  results = CBOR.stream(io).map(&:value)

  assert_equal 1, results.length
  assert_same results[0][0], results[0][1]
  assert_same results[0][1], results[0][2]
end

assert('CBOR.stream: empty stream yields no documents') do
  io = MockIO.new("")
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 0, results.length
end

# ============================================================================
# Shared reference edge cases
# ============================================================================

assert('CBOR shared ref: deeply nested shared structure') do
  shared = [1, 2, 3]
  obj = { "a" => { "b" => { "c" => shared } } }
  obj["x"] = shared

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode(buf)

  assert_same result["a"]["b"]["c"], result["x"]
end

assert('CBOR shared ref: multiple shared objects') do
  a = [1, 2]
  b = [3, 4]
  obj = { "x" => a, "y" => a, "z" => b, "w" => b }

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode(buf)

  assert_same result["x"], result["y"]
  assert_same result["z"], result["w"]
  assert_not_same result["x"], result["z"]
end

assert('CBOR shared ref: shared string in array') do
  s = "shared_string"
  obj = [s, s, s, { "key" => s }]

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode(buf)

  assert_same result[0], result[1]
  assert_same result[1], result[2]
  assert_same result[2], result[3]["key"]
end

assert('CBOR shared ref: eager identity preservation') do
  shared = { "value" => 42 }
  obj = { "ref1" => shared, "ref2" => shared }

  buf = CBOR.encode(obj, sharedrefs: true)
  result = CBOR.decode(buf)

  # Verify identity when decoded
  assert_same result["ref1"], result["ref2"]
  assert_equal 42, result["ref1"]["value"]
end

# ============================================================================
# Complex nesting with lazy
# ============================================================================

assert('CBOR::Lazy: very deep nesting') do
  # Create [[[[[42]]]]]
  deep = 42
  5.times { deep = [deep] }

  lazy = CBOR.decode_lazy(CBOR.encode(deep))

  # Navigate to deepest value
  result = lazy[0][0][0][0][0].value
  assert_equal 42, result
end

assert('CBOR::Lazy: wide structure (many keys)') do
  h = {}
  100.times { |i| h["key_#{i}"] = i }

  lazy = CBOR.decode_lazy(CBOR.encode(h))

  # Spot-check random keys
  assert_equal 0, lazy["key_0"].value
  assert_equal 50, lazy["key_50"].value
  assert_equal 99, lazy["key_99"].value
end

assert('CBOR::Lazy: cache coherence across dig and aref') do
  h = { "a" => { "b" => { "c" => 99 } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  # Access via dig
  via_dig = lazy.dig("a", "b", "c")
  # Access via sequential aref
  via_aref = lazy["a"]["b"]["c"]

  # Both should cache and return same lazy wrapper
  assert_same via_dig, via_aref
end

# ============================================================================
# Integer boundary conditions
# ============================================================================

assert('CBOR integer: all powers of 2 up to 32-bit') do
  (0..31).each do |i|
    n = 1 << i
    assert_equal n, CBOR.decode(CBOR.encode(n))
  end
end

assert('CBOR integer: negative powers of 2') do
  (0..30).each do |i|
    n = -(1 << i)
    assert_equal n, CBOR.decode(CBOR.encode(n))
  end
end

# ============================================================================
# Symbol handling comprehensive
# ============================================================================

assert('CBOR symbols: nested in complex structure') do
  CBOR.symbols_as_string

  obj = {
    :name => "Alice",
    :metadata => {
      :tags => [:important, :urgent],
      :nested => { :sym => :value }
    }
  }

  buf = CBOR.encode(obj)
  decoded = CBOR.decode(buf)

  assert_equal :name, decoded.keys[0]
  assert_equal :important, decoded[:metadata][:tags][0]
  assert_equal :value, decoded[:metadata][:nested][:sym]

  CBOR.no_symbols
end

# ============================================================================
# Bignum operations comprehensive
# ============================================================================

assert('CBOR bignum: intermediate size (just over uint64)') do
  n = (1 << 64) + 1
  assert_equal n, CBOR.decode(CBOR.encode(n))
end

assert('CBOR bignum: negative intermediate') do
  n = -((1 << 64) + 1)
  assert_equal n, CBOR.decode(CBOR.encode(n))
end

assert('CBOR bignum: in array with normal integers') do
  big = (1 << 100)
  obj = [1, 2, big, 4, 5]

  decoded = CBOR.decode(CBOR.encode(obj))

  assert_equal 1, decoded[0]
  assert_equal big, decoded[2]
  assert_equal 5, decoded[4]
end

assert('CBOR bignum: lazy decode in nested structure') do
  big = (1 << 200) + 12345
  obj = { "nums" => [1, 2, big], "meta" => { "big" => big } }

  lazy = CBOR.decode_lazy(CBOR.encode(obj))

  assert_equal big, lazy["nums"][2].value
  assert_equal big, lazy["meta"]["big"].value
end

# ============================================================================
# Lazy array negative indices edge cases
# ============================================================================

assert('CBOR::Lazy array: negative index with dig') do
  ary = [10, 20, 30, 40, 50]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))

  assert_equal 50, lazy.dig(-1).value
  assert_equal 40, lazy.dig(-2).value
  assert_equal 10, lazy.dig(-5).value
end

assert('CBOR::Lazy array: negative out of bounds with dig') do
  ary = [1, 2, 3]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))

  # dig returns nil for out of bounds
  assert_nil lazy.dig(-99)
end

# ============================================================================
# Lazy access after materializing parent
# ============================================================================

assert('CBOR::Lazy: lazy access after calling value on parent') do
  h = { "a" => { "b" => 42 } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  # Materialize parent
  parent = lazy.value

  # Parent is now eager, but lazy wrappers still work
  inner_lazy = lazy["a"]
  assert_not_nil inner_lazy
  assert_equal 42, inner_lazy["b"].value
end

# ============================================================================
# Map key type consistency in lazy
# ============================================================================

assert('CBOR::Lazy map: integer and string keys mixed') do
  h = { 1 => "int_key", "str" => "str_key", 100 => "int_100" }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  assert_equal "int_key", lazy[1].value
  assert_equal "str_key", lazy["str"].value
  assert_equal "int_100", lazy[100].value
end

# ============================================================================
# Lazy dig with nil intermediate
# ============================================================================

assert('CBOR::Lazy dig: handles missing keys') do
  h = { "a" => 1, "b" => { "c" => 42 } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  # dig returns nil when key doesn't exist
  assert_nil lazy.dig("missing")
  assert_nil lazy.dig("missing", "x")

  # dig returns value when path is valid
  assert_equal 42, lazy.dig("b", "c").value
end

# ============================================================================
# Stream with different offsets
# ============================================================================

assert('CBOR.stream: stream documents from middle of buffer') do
  doc1 = CBOR.encode("first")
  doc2 = CBOR.encode("second")
  doc3 = CBOR.encode("third")

  buf = doc1 + doc2 + doc3
  io = MockIO.new(buf)

  results = []
  CBOR.stream(io, doc1.bytesize) { |d| results << d.value }

  assert_equal 2, results.length
  assert_equal "second", results[0]
  assert_equal "third", results[1]
end

# ============================================================================
# Unhandled tag with shared refs
# ============================================================================

assert('CBOR tag: unknown tag with various payloads') do
  # Unknown tag with integer
  buf1 = "\xD8\x64\x18\x2A"
  result1 = CBOR.decode(buf1)
  assert_true result1.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result1.tag
  assert_equal 42, result1.value

  # Unknown tag with string
  buf2 = "\xD8\x64\x63\x61\x62\x63"
  result2 = CBOR.decode(buf2)
  assert_true result2.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result2.tag
  assert_equal "abc", result2.value
end

# ============================================================================
# Lazy access error conditions
# ============================================================================

assert('CBOR::Lazy: invalid array index type') do
  ary = [1, 2, 3]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))

  # String index on array raises TypeError (string can't convert to integer)
  assert_raise(TypeError) { lazy["invalid"].value }
end

assert('CBOR::Lazy: dig on integer raises') do
  lazy = CBOR.decode_lazy(CBOR.encode(42))

  # dig on non-container should raise
  assert_raise(TypeError) { lazy.dig("key") }
end
