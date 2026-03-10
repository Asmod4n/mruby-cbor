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

assert('CBOR bignum zero encoded as normal integer') do
  assert_equal 0, CBOR.decode(CBOR.encode(0))
end

assert('CBOR bignum small negative encoded as normal integer') do
  assert_equal -1, CBOR.decode(CBOR.encode(-1))
  assert_equal -10, CBOR.decode(CBOR.encode(-10))
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
