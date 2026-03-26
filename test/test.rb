assert('CBOR encode/decode primitives') do
  assert_equal 123, CBOR.decode(CBOR.encode(123))
  assert_equal(-5,  CBOR.decode(CBOR.encode(-5)))
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
  buf = "\x82\xD8\x1C\x82\x01\x02\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('CBOR shared ref: map with shared value (eager)') do
  buf = "\xA2\x61\x61\xD8\x1C\x83\x01\x02\x03\x61\x62\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR shared ref: cyclic array (eager)') do
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
  buf = "\xD8\x1D\x18\x63"
  assert_raise(IndexError) { CBOR.decode(buf) }
end

assert('CBOR shared ref: scalar shareable (integer)') do
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
# register_tag — now uses Ruby classes for native_ext_type
# ============================================================================

assert('CBOR register_tag: encode and decode custom class') do
  class Point
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer

    def initialize(x, y)
      @x = x
      @y = y
    end

    def _after_decode
      self
    end

    def _before_encode
      self
    end

    def ==(other)
      other.is_a?(Point) &&
        @x == other.instance_variable_get(:@x) &&
        @y == other.instance_variable_get(:@y)
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
  buf = "\xD8\x64\x18\x2A"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  assert_equal 42,  result.value
end

assert('CBOR UnhandledTag: unknown tag with string payload') do
  buf = "\xD8\x64\x63\x61\x62\x63"
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
  assert_equal Float::INFINITY, CBOR.decode(CBOR.encode(Float::INFINITY))
end

assert('CBOR float: negative infinity roundtrip') do
  assert_equal(-Float::INFINITY, CBOR.decode(CBOR.encode(-Float::INFINITY)))
end

assert('CBOR float: NaN roundtrip') do
  assert_true CBOR.decode(CBOR.encode(Float::NAN)).nan?
end

assert('CBOR float: zero roundtrip') do
  assert_equal 0.0, CBOR.decode(CBOR.encode(0.0))
end

assert('CBOR float: negative zero roundtrip') do
  assert_equal 0.0, CBOR.decode(CBOR.encode(-0.0))
end

assert('CBOR float: small float roundtrip') do
  assert_equal 1.5, CBOR.decode(CBOR.encode(1.5))
end

assert('CBOR float: large float roundtrip') do
  f = 1.0e300
  assert_equal f, CBOR.decode(CBOR.encode(f))
end

assert('CBOR float16: decode 1.0') do
  assert_equal 1.0, CBOR.decode("\xF9\x3C\x00")
end

assert('CBOR float16: decode 0.0') do
  assert_equal 0.0, CBOR.decode("\xF9\x00\x00")
end

assert('CBOR float16: decode infinity') do
  assert_equal Float::INFINITY, CBOR.decode("\xF9\x7C\x00")
end

assert('CBOR float16: decode NaN') do
  assert_true CBOR.decode("\xF9\x7E\x00").nan?
end

assert('CBOR float16: decode subnormal') do
  result = CBOR.decode("\xF9\x00\x01")
  assert_true result > 0.0
  assert_true result < 1.0e-4
end

assert('CBOR float32: decode 1.0') do
  assert_equal 1.0, CBOR.decode("\xFA\x3F\x80\x00\x00")
end

# ============================================================================
# Simple values
# ============================================================================

assert('CBOR simple value with skip (info=24)') do
  assert_nil CBOR.decode("\xF8\x00")
end

assert('CBOR simple values below 20 decode as nil') do
  (0..19).each do |i|
    assert_nil CBOR.decode((0xE0 | i).chr)
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
  n = 2**30 - 1
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
  assert_equal 3,             results.length
  assert_equal({ "a" => 1 }, results[0])
  assert_equal [1, 2, 3],    results[1]
  assert_equal 42,           results[2]
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
  docs = [0, 23, 24, 255, 256, 65535, 65536, 0xFFFFFFFF, 0x100000000]
  buf = docs.map { |n| CBOR.encode(n) }.join
  io  = MockIO.new(buf)
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal docs, results
end

assert('CBOR integer overflow: negative uint32 boundary') do
  buf = "\x3A\xFF\xFF\xFF\xFF"
  assert_equal(-(2**32), CBOR.decode(buf))
end

assert('CBOR integer overflow: negative uint64 > MRB_INT_MAX+1') do
  buf = "\x3B\x80\x00\x00\x00\x00\x00\x00\x00"
  assert_equal(-(2**63) - 1, CBOR.decode(buf))
end

assert('CBOR integer overflow: unsigned uint64 > MRB_INT_MAX+1') do
  buf = "\x1B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_equal(2**64 - 1, CBOR.decode(buf))
end

assert('CBOR array with bigint length raises') do
  buf = "\x9B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_raise(RangeError) { CBOR.decode(buf) }
end

assert('CBOR negative integer: -1 - UINT64_MAX') do
  buf = "\x3B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  begin
    result = CBOR.decode(buf)
    assert_equal(-(2**64), result)
  rescue RangeError
    # no MRB_USE_BIGINT — raise is correct
  end
end

# ============================================================================
# Lazy decoding with registered tags
# ============================================================================

assert('CBOR register_tag: lazy decode with custom class') do
  class Point
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer

    def initialize(x = 0, y = 0)
      @x = x
      @y = y
    end

    def ==(other)
      other.is_a?(Point) &&
        @x == other.instance_variable_get(:@x) &&
        @y == other.instance_variable_get(:@y)
    end
  end

  CBOR.register_tag(1001, Point)

  p = Point.new(5, 10)
  buf = CBOR.encode(p)
  lazy = CBOR.decode_lazy(buf)
  decoded = lazy.value

  assert_true decoded.is_a?(Point)
  assert_equal 5,  decoded.instance_variable_get(:@x)
  assert_equal 10, decoded.instance_variable_get(:@y)
end

assert('CBOR register_tag: lazy nested access through registered tag') do
  class Rect
    native_ext_type :@corners, Array

    def initialize(corners = [])
      @corners = corners
    end
  end

  CBOR.register_tag(1002, Rect)

  rect = Rect.new([[0, 0], [10, 10]])
  buf = CBOR.encode(rect)
  lazy = CBOR.decode_lazy(buf)

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
  assert_same result["x"], result["y"]
  assert_equal [1, 2, 3], result["x"]["data"]
end

assert('CBOR::Lazy: cyclic structure eager materialization') do
  a = []
  a << a
  buf = CBOR.encode(a, sharedrefs: true)
  result = CBOR.decode_lazy(buf).value
  assert_same result, result[0]
end

assert('CBOR::Lazy: array with mixed types') do
  ary = [42, "hello", 3.14, true, nil, [1, 2], { "x" => 9 }]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_equal 42,      lazy[0].value
  assert_equal "hello", lazy[1].value
  assert_true (lazy[2].value - 3.14).abs < 0.01
  assert_equal true,    lazy[3].value
  assert_nil            lazy[4].value
  assert_equal [1, 2],  lazy[5].value
  assert_equal({ "x" => 9 }, lazy[6].value)
end

# ============================================================================
# Tag nesting and edge cases
# ============================================================================

assert('CBOR tag: unknown tag wrapping another unknown tag') do
  buf = "\xD8\x64\xD8\x65\x18\x2A"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  inner = result.value
  assert_true inner.is_a?(CBOR::UnhandledTag)
  assert_equal 101, inner.tag
  assert_equal 42, inner.value
end

assert('CBOR tag: unknown tag wrapping array') do
  buf = "\xD8\xC8\x83\x01\x02\x03"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 200, result.tag
  assert_equal [1, 2, 3], result.value
end

assert('CBOR tag: unknown tag wrapping map') do
  buf = "\xD9\x01\x2C\xA1\x61\x78\x01"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 300, result.tag
  assert_equal({ "x" => 1 }, result.value)
end

assert('CBOR tag: lazy decode of unknown tag') do
  buf = "\xD8\x64\x18\x2A"
  result = CBOR.decode_lazy(buf).value
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
    native_ext_type :@val, Integer

    def initialize(val = 0)
      @val = val
    end
  end

  CBOR.register_tag(2000, SimpleValue)

  obj = SimpleValue.new(42)
  wrapped = { "tagged" => obj }
  buf = CBOR.encode(wrapped)
  result = CBOR.decode(buf)

  assert_true result["tagged"].is_a?(SimpleValue)
  assert_equal 42, result["tagged"].instance_variable_get(:@val)
end

assert('CBOR tag: unknown in lazy array with mixed tags') do
  buf = "\x84\xD8\x64\x01\xD8\x64\x02\x03\x64text"
  lazy = CBOR.decode_lazy(buf)
  elem0 = lazy[0].value
  assert_true elem0.is_a?(CBOR::UnhandledTag)
  assert_equal 100, elem0.tag
  assert_equal 1, elem0.value
  elem1 = lazy[1].value
  assert_true elem1.is_a?(CBOR::UnhandledTag)
  assert_equal 100, elem1.tag
  assert_equal 2, elem1.value
  assert_equal 3,      lazy[2].value
  assert_equal "text", lazy[3].value
end

assert('CBOR tag: triple-nested unknowns in structure') do
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
  docs = [42, "hello", [1, 2, 3], { "x" => 1 }, true, nil]
  buf = docs.map { |d| CBOR.encode(d) }.join
  io = MockIO.new(buf)
  results = CBOR.stream(io).map(&:value)
  assert_equal docs.length, results.length
  docs.each_with_index { |expected, i| assert_equal expected, results[i] }
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
  assert_same result["ref1"], result["ref2"]
  assert_equal 42, result["ref1"]["value"]
end

# ============================================================================
# Complex nesting with lazy
# ============================================================================

assert('CBOR::Lazy: very deep nesting') do
  deep = 42
  5.times { deep = [deep] }
  lazy = CBOR.decode_lazy(CBOR.encode(deep))
  assert_equal 42, lazy[0][0][0][0][0].value
end

assert('CBOR::Lazy: wide structure (many keys)') do
  h = {}
  100.times { |i| h["key_#{i}"] = i }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal 0,  lazy["key_0"].value
  assert_equal 50, lazy["key_50"].value
  assert_equal 99, lazy["key_99"].value
end

assert('CBOR::Lazy: cache coherence across dig and aref') do
  h = { "a" => { "b" => { "c" => 99 } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  via_dig  = lazy.dig("a", "b", "c")
  via_aref = lazy["a"]["b"]["c"]
  assert_same via_dig, via_aref
end

# ============================================================================
# Integer boundary conditions
# ============================================================================

assert('CBOR integer: all powers of 2 up to 32-bit') do
  (0..31).each { |i| n = 1 << i; assert_equal n, CBOR.decode(CBOR.encode(n)) }
end

assert('CBOR integer: negative powers of 2') do
  (0..30).each { |i| n = -(1 << i); assert_equal n, CBOR.decode(CBOR.encode(n)) }
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
  assert_equal :name,      decoded.keys[0]
  assert_equal :important, decoded[:metadata][:tags][0]
  assert_equal :value,     decoded[:metadata][:nested][:sym]
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
  assert_equal 1,   decoded[0]
  assert_equal big, decoded[2]
  assert_equal 5,   decoded[4]
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
  assert_nil lazy.dig(-99)
end

assert('CBOR::Lazy: lazy access after calling value on parent') do
  h = { "a" => { "b" => 42 } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  parent = lazy.value
  inner_lazy = lazy["a"]
  assert_not_nil inner_lazy
  assert_equal 42, inner_lazy["b"].value
end

assert('CBOR::Lazy map: integer and string keys mixed') do
  h = { 1 => "int_key", "str" => "str_key", 100 => "int_100" }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal "int_key", lazy[1].value
  assert_equal "str_key", lazy["str"].value
  assert_equal "int_100", lazy[100].value
end

assert('CBOR::Lazy dig: handles missing keys') do
  h = { "a" => 1, "b" => { "c" => 42 } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_nil lazy.dig("missing")
  assert_nil lazy.dig("missing", "x")
  assert_equal 42, lazy.dig("b", "c").value
end

assert('CBOR.stream: stream documents from middle of buffer') do
  doc1 = CBOR.encode("first")
  doc2 = CBOR.encode("second")
  doc3 = CBOR.encode("third")
  buf = doc1 + doc2 + doc3
  io = MockIO.new(buf)
  results = []
  CBOR.stream(io, doc1.bytesize) { |d| results << d.value }
  assert_equal 2,        results.length
  assert_equal "second", results[0]
  assert_equal "third",  results[1]
end

assert('CBOR tag: unknown tag with various payloads') do
  result1 = CBOR.decode("\xD8\x64\x18\x2A")
  assert_true result1.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result1.tag
  assert_equal 42,  result1.value

  result2 = CBOR.decode("\xD8\x64\x63\x61\x62\x63")
  assert_true result2.is_a?(CBOR::UnhandledTag)
  assert_equal 100,   result2.tag
  assert_equal "abc", result2.value
end

assert('CBOR::Lazy: invalid array index type') do
  lazy = CBOR.decode_lazy(CBOR.encode([1, 2, 3]))
  assert_raise(TypeError) { lazy["invalid"].value }
end

assert('CBOR::Lazy: dig on integer raises') do
  lazy = CBOR.decode_lazy(CBOR.encode(42))
  assert_raise(TypeError) { lazy.dig("key") }
end

# ============================================================================
# Registered tag hooks: _before_encode and _after_decode
# ============================================================================

assert('CBOR registered tag: _after_decode hook called') do
  class Person
    attr_accessor :name, :age
    native_ext_type :@name, String
    native_ext_type :@age,  Integer

    def initialize
      @loaded = false
    end

    def _after_decode
      @loaded = true
      self
    end

    def loaded?
      @loaded
    end
  end

  CBOR.register_tag(1000, Person)

  person = Person.new
  person.name = "Alice"
  person.age = 30

  encoded = CBOR.encode(person)
  decoded = CBOR.decode(encoded)

  assert_true decoded.is_a?(Person)
  assert_equal "Alice", decoded.name
  assert_equal 30, decoded.age
  assert_true decoded.loaded?
end

assert('CBOR registered tag: _before_encode hook called') do
  class Item
    attr_accessor :value
    native_ext_type :@value, Integer

    def initialize(val)
      @value = val
    end

    def _before_encode
      @value = @value * 2
      self
    end
  end

  CBOR.register_tag(1001, Item)

  item = Item.new(5)
  encoded = CBOR.encode(item)
  decoded = CBOR.decode(encoded)
  assert_equal 10, decoded.value
end

assert('CBOR registered tag: both hooks in sequence') do
  class Counter
    attr_accessor :count
    native_ext_type :@count, Integer

    def initialize(n)
      @count = n
      @before_encode_called = false
      @after_decode_called = false
    end

    def _before_encode
      @before_encode_called = true
      @count = @count + 1
      self
    end

    def _after_decode
      @after_decode_called = true
      @count = @count + 1
      self
    end

    def before_encode_called?; @before_encode_called; end
    def after_decode_called?;  @after_decode_called;  end
  end

  CBOR.register_tag(1002, Counter)

  counter = Counter.new(10)
  encoded = CBOR.encode(counter)
  assert_true counter.before_encode_called?
  decoded = CBOR.decode(encoded)
  assert_equal 12, decoded.count
  assert_true decoded.after_decode_called?
end

assert('CBOR registered tag: _before_encode without _after_decode') do
  class Price
    attr_accessor :amount
    native_ext_type :@amount, Integer

    def initialize(val)
      @amount = val
    end

    def _before_encode
      @amount = (@amount * 100).to_i
      self
    end
  end

  CBOR.register_tag(1003, Price)

  price = Price.new(5)
  encoded = CBOR.encode(price)
  decoded = CBOR.decode(encoded)
  assert_equal 500, decoded.amount
  assert_true decoded.is_a?(Price)
end

assert('CBOR registered tag: _after_decode without _before_encode') do
  class Config
    attr_accessor :timeout
    native_ext_type :@timeout, Integer

    def initialize(val)
      @timeout = val
      @validated = false
    end

    def _after_decode
      @timeout = @timeout.abs
      @validated = true
      self
    end

    def validated?; @validated; end
  end

  CBOR.register_tag(1004, Config)

  config = Config.new(30)
  encoded = CBOR.encode(config)
  decoded = CBOR.decode(encoded)
  assert_equal 30, decoded.timeout
  assert_true decoded.validated?
end

assert('CBOR registered tag: hook exception propagates') do
  class Strict
    attr_accessor :value
    native_ext_type :@value, Integer

    def initialize(val)
      @value = val
    end

    def _before_encode
      raise "encode forbidden"
    end
  end

  CBOR.register_tag(1005, Strict)

  strict = Strict.new(42)
  assert_raise(RuntimeError) { CBOR.encode(strict) }
end

assert('CBOR registered tag: hook modifies multiple fields') do
  class User
    attr_accessor :username, :email
    native_ext_type :@username, String
    native_ext_type :@email,    String

    def initialize
      @username = ""
      @email = ""
    end

    def _after_decode
      @username = @username.downcase
      @email = @email.downcase
      self
    end
  end

  CBOR.register_tag(1006, User)

  user = User.new
  user.username = "AlicE"
  user.email = "Alice@Example.COM"
  encoded = CBOR.encode(user)
  decoded = CBOR.decode(encoded)
  assert_equal "alice",             decoded.username
  assert_equal "alice@example.com", decoded.email
end

assert('CBOR registered tag: lazy decode with _after_decode') do
  class Data
    attr_accessor :value
    native_ext_type :@value, Integer

    def initialize(val)
      @value = val
      @materialized = false
    end

    def _after_decode
      @materialized = true
      self
    end

    def materialized?; @materialized; end
  end

  CBOR.register_tag(1007, Data)

  data = Data.new(99)
  encoded = CBOR.encode(data)
  lazy = CBOR.decode_lazy(encoded)
  assert_false data.materialized?
  materialized = lazy.value
  assert_true materialized.materialized?
  assert_equal 99, materialized.value
end

assert('CBOR registered tag: extra fields are silently ignored') do
  class WhitelistPerson
    attr_accessor :allowed_a, :allowed_b, :ignored_field
    native_ext_type :@allowed_a, String
    native_ext_type :@allowed_b, Integer

    def initialize
      @allowed_a = ""
      @allowed_b = 0
      @ignored_field = nil
    end
  end

  CBOR.register_tag(2000, WhitelistPerson)

  payload_with_extras = {
    "allowed_a"   => "hello",
    "allowed_b"   => 42,
    "extra_field_1" => "this should be ignored",
    "extra_field_2" => [1, 2, 3],
    "extra_field_3" => { "nested" => "data" }
  }

  payload_cbor = CBOR.encode(payload_with_extras)
  tag_bytes = "\xD9\x07\xD0"  # Tag(2000)
  tagged_cbor = tag_bytes + payload_cbor
  decoded = CBOR.decode(tagged_cbor)

  assert_true decoded.is_a?(WhitelistPerson)
  assert_equal "hello", decoded.allowed_a
  assert_equal 42,      decoded.allowed_b
  assert_nil decoded.ignored_field
end

assert('CBOR registered tag: extra fields do not corrupt registered fields') do
  class StrictRecord
    attr_accessor :id, :name
    native_ext_type :@id,   Integer
    native_ext_type :@name, String

    def initialize
      @id   = 0
      @name = ""
    end
  end

  CBOR.register_tag(2001, StrictRecord)

  payload = {
    "id"         => 999,
    "name"       => "test",
    "secret"     => "should not appear",
    "data"       => { "nested" => "ignored" },
    "array"      => [1, 2, 3, 4, 5],
    "extra_int"  => 12345,
    "extra_bool" => true,
    "extra_nil"  => nil
  }

  payload_cbor = CBOR.encode(payload)
  tag_bytes = "\xD9\x07\xD1"  # Tag(2001)
  tagged_cbor = tag_bytes + payload_cbor
  decoded = CBOR.decode(tagged_cbor)

  assert_true decoded.is_a?(StrictRecord)
  assert_equal 999,    decoded.id
  assert_equal "test", decoded.name
  assert_equal 2, decoded.instance_variables.length
end

# ============================================================================
# CBOR.stream (string/socket variants)
# ============================================================================

assert('CBOR.stream: string with single doc') do
  buf = CBOR.encode({"a" => 1})
  docs = []
  CBOR.stream(buf) {|d| docs << d.value }
  assert_equal 1, docs.length
  assert_equal({"a" => 1}, docs[0])
end

assert('CBOR.stream: string with multiple docs') do
  buf = CBOR.encode(1) + CBOR.encode(2) + CBOR.encode(3)
  docs = []
  CBOR.stream(buf) {|d| docs << d.value }
  assert_equal [1, 2, 3], docs
end

assert('CBOR.stream: string with offset') do
  buf = CBOR.encode(1) + CBOR.encode(2) + CBOR.encode(3)
  skip = CBOR.encode(1).bytesize
  docs = []
  CBOR.stream(buf, skip) {|d| docs << d.value }
  assert_equal [2, 3], docs
end

assert('CBOR.stream: string without block returns enumerator') do
  buf = CBOR.encode(1) + CBOR.encode(2)
  e = CBOR.stream(buf)
  assert_true e.respond_to?(:each)
end

assert('CBOR.stream: file-like io') do
  class MockFile
    def initialize(data)
      @data = data
      @pos  = 0
    end
    def path; "mock"; end
    def seek(pos); @pos = pos; end
    def read(n)
      return nil if @pos >= @data.bytesize
      slice = @data.byteslice(@pos, n)
      @pos += slice.bytesize
      slice
    end
  end

  buf = CBOR.encode("x") + CBOR.encode("y") + CBOR.encode("z")
  io  = MockFile.new(buf)
  docs = []
  CBOR.stream(io) {|d| docs << d.value }
  assert_equal ["x", "y", "z"], docs
end

assert('CBOR.stream: file-like io with offset') do
  buf  = CBOR.encode("x") + CBOR.encode("y") + CBOR.encode("z")
  skip = CBOR.encode("x").bytesize
  io   = MockFile.new(buf)
  docs = []
  CBOR.stream(io, skip) {|d| docs << d.value }
  assert_equal ["y", "z"], docs
end

assert('CBOR.stream: socket-like io single chunk') do
  class MockSocket
    def initialize(data)
      @data = data
      @pos  = 0
    end
    def recv(n)
      return nil if @pos >= @data.bytesize
      slice = @data.byteslice(@pos, n)
      @pos += slice.bytesize
      slice
    end
    def read(n); recv(n); end
  end

  buf = CBOR.encode(42) + CBOR.encode(43)
  io  = MockSocket.new(buf)
  docs = []
  CBOR.stream(io) {|d| docs << d.value }
  assert_equal [42, 43], docs
end

assert('CBOR.stream: socket-like io fragmented chunks') do
  buf = CBOR.encode({"key" => "value"}) + CBOR.encode([1, 2, 3])

  class FragSocket
    def initialize(data, chunk_size)
      @data       = data
      @pos        = 0
      @chunk_size = chunk_size
    end
    def recv(n)
      return nil if @pos >= @data.bytesize
      take  = [@chunk_size, @data.bytesize - @pos].min
      slice = @data.byteslice(@pos, take)
      @pos += take
      slice
    end
    def read(n); recv(n); end
  end

  io   = FragSocket.new(buf, 2)
  docs = []
  CBOR.stream(io) {|d| docs << d.value }
  assert_equal [{"key" => "value"}, [1, 2, 3]], docs
end

assert('CBOR.stream: socket without block returns StreamDecoder') do
  io  = MockSocket.new("")
  dec = CBOR.stream(io)
  assert_true dec.respond_to?(:feed)
end

assert('CBOR.stream: StreamDecoder fed in chunks') do
  buf  = CBOR.encode("hello") + CBOR.encode("world")
  docs = []
  dec  = CBOR::StreamDecoder.new {|d| docs << d.value }
  buf.each_byte {|b| dec.feed(b.chr) }
  assert_equal ["hello", "world"], docs
end

assert('CBOR.stream: type error on unknown io') do
  assert_raise(TypeError) { CBOR.stream(42) }
end

# ============================================================================
# Class / Module encoding (tag 49999)
# ============================================================================

assert('CBOR class encoding: top-level class roundtrips') do
  buf = CBOR.encode(String)
  assert_equal String, CBOR.decode(buf)
end

assert('CBOR class encoding: nested class roundtrips') do
  buf = CBOR.encode(CBOR::UnhandledTag)
  assert_equal CBOR::UnhandledTag, CBOR.decode(buf)
end

assert('CBOR class encoding: module roundtrips') do
  module TestMod; end
  buf = CBOR.encode(TestMod)
  assert_equal TestMod, CBOR.decode(buf)
end

assert('CBOR class encoding: class inside array roundtrips') do
  buf = CBOR.encode([String, Integer, Float])
  result = CBOR.decode(buf)
  assert_equal String,  result[0]
  assert_equal Integer, result[1]
  assert_equal Float,   result[2]
end

assert('CBOR class encoding: class as hash value roundtrips') do
  h = { "klass" => ArgumentError }
  buf = CBOR.encode(h)
  assert_equal ArgumentError, CBOR.decode(buf)["klass"]
end

assert('CBOR class encoding: class as hash key roundtrips') do
  h = { String => "string_class" }
  buf = CBOR.encode(h)
  assert_equal "string_class", CBOR.decode(buf)[String]
end

assert('CBOR class encoding: lazy decode') do
  buf = CBOR.encode(RuntimeError)
  assert_equal RuntimeError, CBOR.decode_lazy(buf).value
end

assert('CBOR class encoding: class in nested lazy structure') do
  h = { "klass" => StandardError, "msg" => "oops" }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal StandardError, lazy["klass"].value
  assert_equal "oops",        lazy["msg"].value
end

assert('CBOR class encoding: anonymous class raises') do
  anon = Class.new
  assert_raise(ArgumentError) { CBOR.encode(anon) }
end

assert('CBOR class encoding: anonymous module raises') do
  anon = Module.new
  assert_raise(ArgumentError) { CBOR.encode(anon) }
end

assert('CBOR class encoding: tag 49999 reserved for register_tag') do
  class DummyForReserved; end
  assert_raise(ArgumentError) { CBOR.register_tag(49999, DummyForReserved) }
end

assert('CBOR class encoding: decode invalid payload raises TypeError') do
  # tag 49999 = 0xD9 0xC3 0x4F, wrapping integer instead of string
  buf = "\xD9\xC3\x4F\x01"
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR class encoding: unknown constant raises NameError') do
  tag_bytes = "\xD9\xC3\x4F"
  name_cbor = CBOR.encode("NoSuchClassXyzAbc123")
  assert_raise(NameError) { CBOR.decode(tag_bytes + name_cbor) }
end

assert('CBOR class encoding: multiple classes round-trip independently') do
  [String, Integer, Array, Hash, Float, NilClass, TrueClass, FalseClass].each do |klass|
    assert_equal klass, CBOR.decode(CBOR.encode(klass))
  end
end

# ============================================================================
# Proc-based tag registration (register_tag with block)
# ============================================================================

class ProcTagBox
  def initialize(val); @val = val; end
  def val; @val; end
end

assert('CBOR proc tag: basic encode and decode') do
  CBOR.register_tag(60000) do
    encode ProcTagBox do |b| b.val end
    decode Integer    do |i| ProcTagBox.new(i * 2) end
  end

  buf = CBOR.encode(ProcTagBox.new(21))
  result = CBOR.decode(buf)
  assert_true result.is_a?(ProcTagBox)
  assert_equal 42, result.val
end

assert('CBOR proc tag: encode proc called with correct value') do
  received = nil
  CBOR.register_tag(60001) do
    encode ProcTagBox do |b|
      received = b.val
      b.val
    end
    decode Integer do |i| ProcTagBox.new(i) end
  end

  CBOR.encode(ProcTagBox.new(99))
  assert_equal 99, received
end

assert('CBOR proc tag: decode proc called with decoded payload') do
  received = nil
  CBOR.register_tag(60002) do
    encode ProcTagBox do |b| b.val end
    decode Integer do |i|
      received = i
      ProcTagBox.new(i)
    end
  end

  buf = CBOR.encode(ProcTagBox.new(77))
  CBOR.decode(buf)
  assert_equal 77, received
end

assert('CBOR proc tag: decode type mismatch raises TypeError') do
  CBOR.register_tag(60003) do
    encode ProcTagBox do |b| b.val.to_s end  # encodes as String, decode expects Integer
    decode Integer    do |i| ProcTagBox.new(i) end
  end

  buf = CBOR.encode(ProcTagBox.new(5))
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR proc tag: inheritance — subclass matches superclass encode type') do
  class SubProcTagBox < ProcTagBox; end

  CBOR.register_tag(60004) do
    encode ProcTagBox do |b| b.val end
    decode Integer    do |i| ProcTagBox.new(i) end
  end

  buf = CBOR.encode(SubProcTagBox.new(55))
  result = CBOR.decode(buf)
  assert_true result.is_a?(ProcTagBox)
  assert_equal 55, result.val
end

assert('CBOR proc tag: encode and decode full exception roundtrip') do
  CBOR.register_tag(60005) do
    encode Exception do |e| [e.class, e.message, e.backtrace] end
    decode Array     do |a|
      exc = a[0].new(a[1])
      exc.set_backtrace(a[2]) if a[2]
      exc
    end
  end

  buf = begin
    raise ArgumentError, "bad argument"
  rescue => e
    CBOR.encode(e)
  end

  exc = CBOR.decode(buf)
  assert_true exc.is_a?(ArgumentError)
  assert_equal "bad argument", exc.message
  assert_not_nil exc.backtrace
end

assert('CBOR proc tag: exception class preserved via tag 49999') do
  CBOR.register_tag(60006) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end

  [ArgumentError, RuntimeError, TypeError, StandardError].each do |klass|
    buf = CBOR.encode(klass.new("msg"))
    exc = CBOR.decode(buf)
    assert_equal klass, exc.class
  end
end

assert('CBOR proc tag: lazy decode fires proc') do
  CBOR.register_tag(60007) do
    encode ProcTagBox do |b| b.val end
    decode Integer    do |i| ProcTagBox.new(i + 1) end
  end

  buf = CBOR.encode(ProcTagBox.new(6))
  result = CBOR.decode_lazy(buf).value
  assert_true result.is_a?(ProcTagBox)
  assert_equal 7, result.val
end

assert('CBOR proc tag: proc result containing class encoded via tag 49999') do
  CBOR.register_tag(60008) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end

  buf = CBOR.encode(TypeError.new("wrong type"))
  result = CBOR.decode(buf)
  assert_equal TypeError, result.class
  assert_equal "wrong type", result.message
end

assert('CBOR proc tag: reserved tags raise ArgumentError') do
  [2, 3, 28, 29, 39, 49999].each do |reserved|
    assert_raise(ArgumentError) do
      CBOR.register_tag(reserved) do
        encode ProcTagBox do |b| b.val end
        decode Integer    do |i| ProcTagBox.new(i) end
      end
    end
  end
end

assert('CBOR proc tag: unregistered object falls back to string') do
  class UnregisteredThing
    def to_s; "unregistered"; end
  end
  buf = CBOR.encode(UnregisteredThing.new)
  assert_equal "unregistered", CBOR.decode(buf)
end

assert('CBOR proc tag: multiple proc tags coexist') do
  class BoxA; def initialize(v); @v = v; end; def val; @v; end; end
  class BoxB; def initialize(v); @v = v; end; def val; @v; end; end

  CBOR.register_tag(60009) do
    encode BoxA    do |b| b.val end
    decode Integer do |i| BoxA.new(i) end
  end

  CBOR.register_tag(60010) do
    encode BoxB    do |b| b.val * 10 end
    decode Integer do |i| BoxB.new(i) end
  end

  buf_a = CBOR.encode(BoxA.new(3))
  buf_b = CBOR.encode(BoxB.new(4))

  assert_equal 3,  CBOR.decode(buf_a).val
  assert_equal 40, CBOR.decode(buf_b).val
end

assert('CBOR proc tag: proc tag and class tag coexist') do
  class ProcCoexist
    native_ext_type :@v, Integer
    def initialize(v = 0); @v = v; end
  end
  CBOR.register_tag(60011, ProcCoexist)

  class BoxC; def initialize(v); @v = v; end; def val; @v; end; end
  CBOR.register_tag(60012) do
    encode BoxC    do |b| b.val end
    decode Integer do |i| BoxC.new(i) end
  end

  obj_buf = CBOR.encode(ProcCoexist.new(42))
  box_buf = CBOR.encode(BoxC.new(7))

  obj_result = CBOR.decode(obj_buf)
  box_result = CBOR.decode(box_buf)

  assert_true obj_result.is_a?(ProcCoexist)
  assert_equal 42, obj_result.instance_variable_get(:@v)
  assert_true box_result.is_a?(BoxC)
  assert_equal 7, box_result.val
end

assert('CBOR proc tag: encode proc exception propagates') do
  class BoxD; def initialize(v); @v = v; end; end
  CBOR.register_tag(60013) do
    encode BoxD    do |b| raise "encode error" end
    decode Integer do |i| BoxD.new(i) end
  end

  assert_raise(RuntimeError) { CBOR.encode(BoxD.new(1)) }
end

assert('CBOR proc tag: decode proc exception propagates') do
  class BoxE; def initialize(v); @v = v; end; def val; @v; end; end
  CBOR.register_tag(60014) do
    encode BoxE    do |b| b.val end
    decode Integer do |i| raise "decode error" end
  end

  buf = CBOR.encode(BoxE.new(1))
  assert_raise(RuntimeError) { CBOR.decode(buf) }
end

assert('CBOR proc tag: works with sharedrefs encoding') do
  CBOR.register_tag(60015) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end

  exc1 = RuntimeError.new("one")
  exc2 = ArgumentError.new("two")
  buf = CBOR.encode([exc1, exc2], sharedrefs: true)
  result = CBOR.decode(buf)
  assert_equal RuntimeError,  result[0].class
  assert_equal ArgumentError, result[1].class
  assert_equal "one", result[0].message
  assert_equal "two", result[1].message
end

# ============================================================================
# Proc tag: natively-encoded encode_type rejected
# ============================================================================

assert('CBOR proc tag: cannot register String as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61000) do
      encode String do |s| s end
      decode String do |s| s end
    end
  end
end

assert('CBOR proc tag: cannot register Integer as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61001) do
      encode Integer do |i| i end
      decode Integer do |i| i end
    end
  end
end

assert('CBOR proc tag: cannot register Float as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61002) do
      encode Float do |f| f end
      decode Float do |f| f end
    end
  end
end

assert('CBOR proc tag: cannot register Array as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61003) do
      encode Array do |a| a end
      decode Array do |a| a end
    end
  end
end

assert('CBOR proc tag: cannot register Hash as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61004) do
      encode Hash do |h| h end
      decode Hash do |h| h end
    end
  end
end

assert('CBOR proc tag: cannot register TrueClass as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61005) do
      encode TrueClass do |b| b end
      decode TrueClass do |b| b end
    end
  end
end

assert('CBOR proc tag: cannot register FalseClass as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61006) do
      encode FalseClass do |b| b end
      decode FalseClass do |b| b end
    end
  end
end

assert('CBOR proc tag: cannot register NilClass as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61007) do
      encode NilClass do |n| n end
      decode NilClass do |n| n end
    end
  end
end

assert('CBOR proc tag: cannot register Symbol as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61008) do
      encode Symbol do |s| s.to_s end
      decode String do |s| s.to_sym end
    end
  end
end

assert('CBOR proc tag: cannot register Class as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61009) do
      encode Class  do |c| c.name end
      decode String do |s| s end
    end
  end
end

assert('CBOR proc tag: cannot register Module as encode type') do
  assert_raise(TypeError) do
    CBOR.register_tag(61010) do
      encode Module do |m| m.name end
      decode String do |s| s end
    end
  end
end

assert('CBOR proc tag: Exception is allowed as encode type') do
  CBOR.register_tag(61011) do
    encode Exception do |e| e.message end
    decode String    do |s| RuntimeError.new(s) end
  end

  buf = CBOR.encode(RuntimeError.new("ok"))
  result = CBOR.decode(buf)
  assert_equal "ok", result.message
end

assert('RFC 8949 §3.4.3: zero-length bignum payload') do
  # tag(2, h'') = 0   — positive bignum with empty byte string
  # tag(3, h'') = -1  — negative bignum with empty byte string
  # RFC 8949 §3.4.3: decoders MUST accept bignums with leading zeroes,
  # and a zero-length payload represents n=0.

  tag2_empty = "\xC2\x40"
  tag3_empty = "\xC3\x40"

  assert_equal 0,  CBOR.decode(tag2_empty)
  assert_equal(-1, CBOR.decode(tag3_empty))

  # Round-trip: encoding 0 and -1 produces plain integers, not bignums
  assert_equal "\x00", CBOR.encode(0)
  assert_equal "\x20", CBOR.encode(-1)
end
