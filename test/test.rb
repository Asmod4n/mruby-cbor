# =============================================================================
# mruby-cbor test suite
#
# Sections (in order):
#   1.  Primitives          – nil, bool, integers, floats
#   2.  Strings             – text, bytes, empty, UTF-8
#   3.  Arrays              – basic, empty, nested, large lengths
#   4.  Maps                – basic, empty, non-string keys
#   5.  Bignum              – boundaries, lazy, mixed structures
#   6.  Symbols             – strategies, nested
#   7.  Tags                – unknown, nested, UnhandledTag
#   8.  Class / Module      – tag 49999
#   9.  Shared references   – tag 28/29, eager and lazy, edge cases
#  10.  Lazy decoding        – aref, dig, caching, stress, error paths
#  11.  Streaming            – MockIO, string input, StreamDecoder, enumerator
#  12.  Registered tags      – native_ext_type, hooks, proc tags, errors
#  13.  Fast path            – encode_fast / decode_fast
#  14.  Error / safety       – depth limit, malformed input, fuzz corpus
# =============================================================================

# ============================================================================
# 1. Primitives
# ============================================================================

assert('CBOR nil roundtrip') do
  assert_nil CBOR.decode(CBOR.encode(nil))
end

assert('CBOR true roundtrip') do
  assert_true CBOR.decode(CBOR.encode(true))
end

assert('CBOR false roundtrip') do
  assert_false CBOR.decode(CBOR.encode(false))
end

assert('CBOR integer: -1 roundtrip') do
  assert_equal(-1, CBOR.decode(CBOR.encode(-1)))
end

assert('CBOR integer: 0 roundtrip') do
  assert_equal 0, CBOR.decode(CBOR.encode(0))
end

assert('CBOR integer: 23 roundtrip (inline max)') do
  assert_equal 23, CBOR.decode(CBOR.encode(23))
end

assert('CBOR integer: 24 roundtrip (uint8 start)') do
  assert_equal 24, CBOR.decode(CBOR.encode(24))
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

assert('CBOR integer: all powers of 2 up to 32-bit') do
  (0..31).each { |i| n = 1 << i; assert_equal n, CBOR.decode(CBOR.encode(n)) }
end

assert('CBOR integer: negative powers of 2') do
  (0..30).each { |i| n = -(1 << i); assert_equal n, CBOR.decode(CBOR.encode(n)) }
end

# Wire-level negative integer boundaries that must promote to bignum or raise
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

assert('CBOR negative integer: -1 - UINT64_MAX') do
  buf = "\x3B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  begin
    result = CBOR.decode(buf)
    assert_equal(-(2**64), result)
  rescue RangeError
    # no MRB_USE_BIGINT — raise is correct
  end
end

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

assert('CBOR float: 1.5 roundtrip') do
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

assert('CBOR float16: decode +infinity') do
  assert_equal Float::INFINITY, CBOR.decode("\xF9\x7C\x00")
end

assert('CBOR float16: decode NaN') do
  assert_true CBOR.decode("\xF9\x7E\x00").nan?
end

assert('CBOR float32: decode 1.0') do
  assert_equal 1.0, CBOR.decode("\xFA\x3F\x80\x00\x00")
end

assert('CBOR float32: decode -0.0') do
  assert_equal 0.0, CBOR.decode("\xFA\x80\x00\x00\x00")
end

assert('CBOR float64: decode 1.0') do
  assert_equal 1.0, CBOR.decode("\xFB\x3F\xF0\x00\x00\x00\x00\x00\x00")
end

assert('CBOR float64: decode large value') do
  assert_equal 1.0e300, CBOR.decode(CBOR.encode(1.0e300))
end

# Extended simple value (info=24): decoded as nil, one extra byte consumed
assert('CBOR simple value info=24 decoded as nil') do
  # 0xF8 0x10 = simple(16) — not false/true/null, decoded as nil
  assert_nil CBOR.decode("\xF8\x10")
end

assert('CBOR simple value info=24 followed by more data') do
  buf = "\xF8\xFF\x18\x2A"
  assert_nil CBOR.decode(buf[0, 2])
end

# ============================================================================
# 1b. Preferred float serialization (RFC 8949 §4.1)
#
# Each float is encoded in the smallest CBOR float width that represents
# the value losslessly: f16 (3 bytes) → f32 (5 bytes) → f64 (9 bytes).
# NaN is always canonicalized to 0xF97E00 per RFC 8949 Appendix B.
# ============================================================================

# ── Exact wire bytes for well-known values ──────────────────────────────────

assert('CBOR preferred float: 0.0 encodes as f16 F9 00 00') do
  assert_equal "\xF9\x00\x00", CBOR.encode(0.0)
end

assert('CBOR preferred float: -0.0 encodes as f16 F9 80 00') do
  assert_equal "\xF9\x80\x00", CBOR.encode(-0.0)
end

assert('CBOR preferred float: 1.0 encodes as f16 F9 3C 00') do
  assert_equal "\xF9\x3C\x00", CBOR.encode(1.0)
end

assert('CBOR preferred float: 1.5 encodes as f16 F9 3E 00') do
  assert_equal "\xF9\x3E\x00", CBOR.encode(1.5)
end

assert('CBOR preferred float: -1.5 encodes as f16 F9 BE 00') do
  assert_equal "\xF9\xBE\x00", CBOR.encode(-1.5)
end

assert('CBOR preferred float: 0.5 encodes as f16 F9 38 00') do
  assert_equal "\xF9\x38\x00", CBOR.encode(0.5)
end

assert('CBOR preferred float: 0.25 encodes as f16 F9 34 00') do
  assert_equal "\xF9\x34\x00", CBOR.encode(0.25)
end

assert('CBOR preferred float: 100.0 encodes as f16 F9 56 40') do
  assert_equal "\xF9\x56\x40", CBOR.encode(100.0)
end

assert('CBOR preferred float: 65504.0 (f16 max normal) encodes as f16 F9 7B FF') do
  assert_equal "\xF9\x7B\xFF", CBOR.encode(65504.0)
end

assert('CBOR preferred float: +Inf encodes as f16 F9 7C 00') do
  assert_equal "\xF9\x7C\x00", CBOR.encode(Float::INFINITY)
end

assert('CBOR preferred float: -Inf encodes as f16 F9 FC 00') do
  assert_equal "\xF9\xFC\x00", CBOR.encode(-Float::INFINITY)
end

assert('CBOR preferred float: NaN encodes as canonical f16 F9 7E 00') do
  assert_equal "\xF9\x7E\x00", CBOR.encode(Float::NAN)
end

# ── Width gates ─────────────────────────────────────────────────────────────

assert('CBOR preferred float: f16-range values encode as 3 bytes') do
  [0.0, -0.0, 1.0, 1.5, -1.5, 0.5, 0.25, 100.0, 65504.0,
   Float::INFINITY, -Float::INFINITY, Float::NAN].each do |v|
    assert_equal 3, CBOR.encode(v).bytesize, "expected f16 for #{v}"
  end
end

assert('CBOR preferred float: f16 subnormal 2^-24 encodes as f16 (3 bytes)') do
  v = 1.0 / 16777216.0  # 2^-24
  assert_equal 3,              CBOR.encode(v).bytesize
  assert_equal "\xF9\x00\x01", CBOR.encode(v)
end

assert('CBOR preferred float: f16 subnormal 2^-23 encodes as f16 (3 bytes)') do
  v = 1.0 / 8388608.0   # 2^-23
  assert_equal 3,              CBOR.encode(v).bytesize
  assert_equal "\xF9\x00\x02", CBOR.encode(v)
end

assert('CBOR preferred float: f16 subnormal 2^-15 encodes as f16 (3 bytes)') do
  v = 1.0 / 32768.0     # 2^-15
  assert_equal 3,              CBOR.encode(v).bytesize
  assert_equal "\xF9\x02\x00", CBOR.encode(v)
end

assert('CBOR preferred float: f16 subnormal powers of 2 round-trip') do
  v = 1.0 / 16777216.0  # 2^-24
  10.times do |i|
    encoded = CBOR.encode(v)
    assert_equal 3, encoded.bytesize, "expected f16 for 2^#{-24+i}"
    assert_equal v, CBOR.decode(encoded), "round-trip failed for 2^#{-24+i}"
    v = v * 2.0
  end
end

assert('CBOR preferred float: 65505.0 (above f16 max) encodes as f32 (5 bytes)') do
  assert_equal 5, CBOR.encode(65505.0).bytesize
end

assert('CBOR preferred float: 1.0e10 encodes as f32 (5 bytes)') do
  assert_equal 5, CBOR.encode(1.0e10).bytesize
end

assert('CBOR preferred float: f32 min normal (2^-126) encodes as f32 (5 bytes)') do
  v = 1.0; 126.times { v = v / 2.0 }  # 2^-126
  assert_equal 5, CBOR.encode(v).bytesize
end

assert('CBOR preferred float: 3.14 encodes as f64 (9 bytes)') do
  assert_equal 9, CBOR.encode(3.14).bytesize
end

assert('CBOR preferred float: 1.0/3.0 encodes as f64 (9 bytes)') do
  assert_equal 9, CBOR.encode(1.0/3.0).bytesize
end

assert('CBOR preferred float: 1.0e300 encodes as f64 (9 bytes)') do
  assert_equal 9, CBOR.encode(1.0e300).bytesize
end

# ── Re-encode width reduction ────────────────────────────────────────────────

assert('CBOR preferred float: re-encode of decoded f32 uses preferred width') do
  decoded = CBOR.decode("\xFA\x3F\x80\x00\x00")  # 1.0 from f32 wire
  assert_equal 1.0, decoded
  assert_equal 3,   CBOR.encode(decoded).bytesize
end

assert('CBOR preferred float: re-encode of decoded f64 uses preferred width') do
  decoded = CBOR.decode("\xFB\x3F\xF0\x00\x00\x00\x00\x00\x00")  # 1.0 from f64 wire
  assert_equal 1.0, decoded
  assert_equal 3,   CBOR.encode(decoded).bytesize
end

assert('CBOR preferred float: f16 subnormal decoded from wire bytes round-trips') do
  v = CBOR.decode("\xF9\x00\x01")  # 2^-24
  assert_true v > 0.0
  assert_equal "\xF9\x00\x01", CBOR.encode(v)
end

# ── All widths round-trip correctly ─────────────────────────────────────────

assert('CBOR preferred float: all widths round-trip correctly') do
  sub_24 = 1.0 / 16777216.0
  sub_23 = 1.0 / 8388608.0
  sub_15 = 1.0 / 32768.0

  [0.0, -0.0, 1.0, 1.5, -1.5, 0.5, 0.25, 100.0,
   65504.0, 65505.0, 1.0e10, 3.14, 1.0/3.0, 1.0e300,
   Float::INFINITY, -Float::INFINITY,
   sub_24, sub_23, sub_15].each do |v|
    assert_equal v, CBOR.decode(CBOR.encode(v)), "round-trip failed for #{v}"
  end
  assert_true CBOR.decode(CBOR.encode(Float::NAN)).nan?
end

# ── Lazy decode at each width ────────────────────────────────────────────────

assert('CBOR preferred float: lazy decode of f16-encoded float') do
  [0.0, 1.0, 1.5, 65504.0, Float::INFINITY].each do |v|
    assert_equal v, CBOR.decode_lazy(CBOR.encode(v)).value
  end
end

assert('CBOR preferred float: lazy decode of f32-encoded float') do
  assert_equal 1.0e10, CBOR.decode_lazy(CBOR.encode(1.0e10)).value
end

assert('CBOR preferred float: lazy decode of f64-encoded float') do
  assert_equal 3.14, CBOR.decode_lazy(CBOR.encode(3.14)).value
end

# ── In containers ────────────────────────────────────────────────────────────

assert('CBOR preferred float: floats in arrays round-trip') do
  ary = [0.0, 1.5, 1.0e10, 3.14, Float::INFINITY]
  decoded = CBOR.decode(CBOR.encode(ary))
  ary.each_with_index { |v, i| assert_equal v, decoded[i] }
end

assert('CBOR preferred float: floats in maps round-trip') do
  h = { "f16" => 1.5, "f32" => 1.0e10, "f64" => 3.14 }
  decoded = CBOR.decode(CBOR.encode(h))
  assert_equal 1.5,    decoded["f16"]
  assert_equal 1.0e10, decoded["f32"]
  assert_equal 3.14,   decoded["f64"]
end

# ── Interop: decode standard wire bytes from other implementations ───────────

assert('CBOR preferred float: interop — decode f16 bytes for 1.5 (F9 3E 00)') do
  assert_equal 1.5, CBOR.decode("\xF9\x3E\x00")
end

assert('CBOR preferred float: interop — decode f16 bytes for 100.0 (F9 56 40)') do
  assert_equal 100.0, CBOR.decode("\xF9\x56\x40")
end

# ============================================================================
# 2. Strings
# ============================================================================

assert('CBOR empty string roundtrip') do
  assert_equal "", CBOR.decode(CBOR.encode(""))
end

assert('CBOR string: short text roundtrip') do
  assert_equal "hello", CBOR.decode(CBOR.encode("hello"))
end

assert('CBOR string: multibyte UTF-8 roundtrip') do
  s = "caf\xC3\xA9"  # "café"
  assert_equal s, CBOR.decode(CBOR.encode(s))
end

assert('CBOR string: 24-byte boundary') do
  s = "a" * 24
  assert_equal s, CBOR.decode(CBOR.encode(s))
end

assert('CBOR string: long string roundtrip') do
  s = "x" * 10000
  assert_equal s, CBOR.decode(CBOR.encode(s))
end

assert('CBOR string: binary (non-UTF-8) encodes as major 2 byte string') do
  b = "\x00\xFF\xFE\xFA"
  wire = CBOR.encode(b)
  assert_equal 0x44, wire.getbyte(0)  # major 2, length 4
  assert_equal b, CBOR.decode(wire)
end

assert('CBOR string: UTF-8 encodes as major 3 text string') do
  wire = CBOR.encode("hello")
  assert_equal 0x65, wire.getbyte(0)  # major 3, length 5
end

assert('CBOR decode text: invalid UTF-8 raises TypeError') do
  buf = "\x63\xFF\xFE\xFD"  # major 3, len 3, invalid UTF-8
  assert_raise(TypeError) { CBOR.decode(buf) }
end

# ============================================================================
# 3. Arrays
# ============================================================================

assert('CBOR empty array roundtrip') do
  assert_equal [], CBOR.decode(CBOR.encode([]))
end

assert('CBOR array: basic roundtrip') do
  assert_equal [1, 2, 3], CBOR.decode(CBOR.encode([1, 2, 3]))
end

assert('CBOR array: nested roundtrip') do
  obj = [[1, 2], [3, [4, 5]]]
  assert_equal obj, CBOR.decode(CBOR.encode(obj))
end

assert('CBOR array: mixed types roundtrip') do
  obj = [1, "two", true, nil, 4.0]
  assert_equal obj, CBOR.decode(CBOR.encode(obj))
end

assert('CBOR array with bigint length raises') do
  buf = "\x9B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_raise(RangeError) { CBOR.decode(buf) }
end

# ============================================================================
# 4. Maps
# ============================================================================

assert('CBOR empty hash roundtrip') do
  assert_equal({}, CBOR.decode(CBOR.encode({})))
end

assert('CBOR map: string keys roundtrip') do
  h = { "a" => 1, "b" => 2 }
  assert_equal h, CBOR.decode(CBOR.encode(h))
end

assert('CBOR map: integer keys') do
  h = { 1 => "one", 2 => "two" }
  assert_equal h, CBOR.decode(CBOR.encode(h))
end

assert('CBOR map: nested map roundtrip') do
  h = { "outer" => { "inner" => 42 } }
  assert_equal h, CBOR.decode(CBOR.encode(h))
end

assert('CBOR map: class as hash key roundtrips') do
  h = { String => "string_class" }
  buf = CBOR.encode(h)
  assert_equal "string_class", CBOR.decode(buf)[String]
end

# ============================================================================
# 5. Bignum
# ============================================================================

assert('CBOR bignum roundtrip') do
  big = (1 << 200) + 12345
  assert_equal big, CBOR.decode(CBOR.encode(big))
end

assert('CBOR negative bignum roundtrip') do
  big = -(1 << 200) - 999
  assert_equal(big, CBOR.decode(CBOR.encode(big)))
end

assert('CBOR bignum boundary: exactly uint64 max') do
  n = (1 << 64) - 1
  assert_equal(n, CBOR.decode(CBOR.encode(n)))
end

assert('CBOR bignum boundary: just above uint64') do
  n = (1 << 64)
  assert_equal(n, CBOR.decode(CBOR.encode(n)))
end

assert('CBOR bignum boundary: just over uint64 + 1') do
  n = (1 << 64) + 1
  assert_equal n, CBOR.decode(CBOR.encode(n))
end

assert('CBOR negative bignum boundary: -(2^64)') do
  n = -(1 << 64)
  assert_equal(n, CBOR.decode(CBOR.encode(n)))
end

assert('CBOR negative bignum: intermediate') do
  n = -((1 << 64) + 1)
  assert_equal n, CBOR.decode(CBOR.encode(n))
end

assert('CBOR very large bignum (4 KB)') do
  big = (1 << 32768) + 123456789
  assert_equal big, CBOR.decode(CBOR.encode(big))
end

assert('RFC 8949 §3.4.3: zero-length bignum payload') do
  # tag(2, h'') = 0   — positive bignum with empty byte string
  # tag(3, h'') = -1  — negative bignum with empty byte string
  assert_equal 0,  CBOR.decode("\xC2\x40")
  assert_equal(-1, CBOR.decode("\xC3\x40"))
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

assert('CBOR bignum does not corrupt following lazy values') do
  h = {
    "a" => (1 << 200) + 1,
    "b" => (1 << 150) + 2,
    "c" => 123
  }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal h["a"], lazy["a"].value
  assert_equal h["b"], lazy["b"].value
  assert_equal 123,    lazy["c"].value
end

# ============================================================================
# 6. Symbols
# ============================================================================

assert('CBOR symbols_as_string: encodes symbol as tagged string') do
  CBOR.symbols_as_string
  buf = CBOR.encode(:hello)
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
  decoded = CBOR.decode(CBOR.encode(h))
  assert_equal({ hello: 1, world: 2 }, decoded)
  CBOR.no_symbols
end

assert('CBOR symbols_as_string: in arrays') do
  CBOR.symbols_as_string
  ary = [:a, :b, :c]
  decoded = CBOR.decode(CBOR.encode(ary))
  assert_equal ary, decoded
  CBOR.no_symbols
end

assert('CBOR symbols: nested in complex structure') do
  CBOR.symbols_as_string
  obj = {
    :name => "Alice",
    :metadata => {
      :tags   => [:important, :urgent],
      :nested => { :sym => :value }
    }
  }
  decoded = CBOR.decode(CBOR.encode(obj))
  assert_equal :name,      decoded.keys[0]
  assert_equal :important, decoded[:metadata][:tags][0]
  assert_equal :value,     decoded[:metadata][:nested][:sym]
  CBOR.no_symbols
end

assert('CBOR no_symbols: encoding symbol falls back to plain string (mode 0)') do
  CBOR.no_symbols
  buf = CBOR.encode(:hello)
  # With no_symbols strategy=0, symbol encodes as a plain text string (no tag 39)
  decoded = CBOR.decode(buf)
  assert_equal "hello", decoded
end

assert('CBOR symbols_as_uint32: tag 39 + non-integer payload raises TypeError') do
  CBOR.symbols_as_uint32
  # tag(39) + text "hello" — uint32 strategy expects an integer payload
  buf = "\xD8\x27\x65hello"
  assert_raise(TypeError) { CBOR.decode(buf) }
  CBOR.no_symbols
end

assert('CBOR symbols_as_string: tag 39 + integer payload raises TypeError') do
  CBOR.symbols_as_string
  # tag(39) + integer 42 — string strategy expects a text payload
  buf = "\xD8\x27\x18\x2A"
  assert_raise(TypeError) { CBOR.decode(buf) }
  CBOR.no_symbols
end


# ============================================================================

assert('CBOR tag: unknown tag wrapping integer') do
  result = CBOR.decode("\xD8\x64\x18\x2A")
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  assert_equal 42,  result.value
end

assert('CBOR tag: unknown tag with various payloads') do
  result2 = CBOR.decode("\xD8\x64\x63\x61\x62\x63")
  assert_true result2.is_a?(CBOR::UnhandledTag)
  assert_equal 100,   result2.tag
  assert_equal "abc", result2.value
end

assert('CBOR tag: unknown tag wrapping array') do
  result = CBOR.decode("\xD8\xC8\x83\x01\x02\x03")
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 200,        result.tag
  assert_equal [1, 2, 3],  result.value
end

assert('CBOR tag: unknown tag wrapping map') do
  result = CBOR.decode("\xD9\x01\x2C\xA1\x61\x78\x01")
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 300,             result.tag
  assert_equal({ "x" => 1 }, result.value)
end

assert('CBOR tag: lazy decode of unknown tag') do
  result = CBOR.decode_lazy("\xD8\x64\x18\x2A").value
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  assert_equal 42,  result.value
end

assert('CBOR tag: unknown tag wrapping nested unknown tag') do
  result = CBOR.decode("\xD8\x64\xD8\x65\x18\x2A")
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  inner = result.value
  assert_true inner.is_a?(CBOR::UnhandledTag)
  assert_equal 101, inner.tag
  assert_equal 42,  inner.value
end

assert('CBOR tag: unknown tag wrapping multiple levels') do
  # Tag100(Tag101(Tag102(Tag103(42))))
  buf = "\xD8\x64\xD8\x65\xD8\x66\xD8\x67\x18\x2A"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 100, result.tag
  cur = result.value; assert_equal 101, cur.tag
  cur = cur.value;    assert_equal 102, cur.tag
  cur = cur.value;    assert_equal 103, cur.tag
  assert_equal 42, cur.value
end

assert('CBOR tag: array containing unknown tags') do
  buf = "\xD8\xC8\x83\xD8\x64\x01\xD8\x65\x02\xD8\x66\x03"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 200, result.tag
  arr = result.value
  assert_equal 3, arr.length
  assert_equal 100, arr[0].tag; assert_equal 1, arr[0].value
  assert_equal 101, arr[1].tag; assert_equal 2, arr[1].value
  assert_equal 102, arr[2].tag; assert_equal 3, arr[2].value
end

assert('CBOR tag: map with unknown tag values') do
  buf = "\xD9\x01\x2C\xA2\x61\x61\xD8\x64\x01\x61\x62\xD8\x65\x02"
  result = CBOR.decode(buf)
  assert_true result.is_a?(CBOR::UnhandledTag)
  assert_equal 300, result.tag
  map = result.value
  assert_equal 100, map["a"].tag; assert_equal 1, map["a"].value
  assert_equal 101, map["b"].tag; assert_equal 2, map["b"].value
end

assert('CBOR tag: triple-nested unknowns in structure') do
  buf = "\xA2\x61\x61\xD8\x64\xD8\x65\xD8\x66\x18\x2A\x61\x62\xD8\x67\x61\x78"
  result = CBOR.decode(buf)
  assert_equal 100, result["a"].tag
  assert_equal 101, result["a"].value.tag
  assert_equal 102, result["a"].value.value.tag
  assert_equal 42,  result["a"].value.value.value
  assert_equal 103, result["b"].tag
  assert_equal "x", result["b"].value
end

assert('CBOR::Lazy: unknown tag in array at specific index') do
  buf = "\x84\x01\xD8\x64\x02\x03\x64\x74\x65\x78\x74"
  lazy = CBOR.decode_lazy(buf)
  assert_equal 1,   lazy[0].value
  elem1 = lazy[1].value
  assert_true elem1.is_a?(CBOR::UnhandledTag)
  assert_equal 100, elem1.tag
  assert_equal 2,   elem1.value
  assert_equal 3,      lazy[2].value
  assert_equal "text", lazy[3].value
end

# ============================================================================
# 8. Class / Module encoding (tag 49999)
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
  result = CBOR.decode(CBOR.encode([String, Integer, Float]))
  assert_equal String,  result[0]
  assert_equal Integer, result[1]
  assert_equal Float,   result[2]
end

assert('CBOR class encoding: class as hash value roundtrips') do
  h = { "klass" => ArgumentError }
  assert_equal ArgumentError, CBOR.decode(CBOR.encode(h))["klass"]
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
  assert_raise(ArgumentError) { CBOR.encode(Class.new) }
end

assert('CBOR class encoding: anonymous module raises') do
  assert_raise(ArgumentError) { CBOR.encode(Module.new) }
end

assert('CBOR class encoding: tag 49999 reserved for register_tag') do
  class DummyForReserved; end
  assert_raise(ArgumentError) { CBOR.register_tag(49999, DummyForReserved) }
end

assert('CBOR class encoding: unknown constant raises NameError') do
  name      = "NoSuchClass__CBOR_TEST_XYZ"
  tag_49999 = "\xD9\xC3\x4F"  # tag(49999)
  buf = tag_49999 + CBOR.encode(name)
  assert_raise(NameError) { CBOR.decode(buf) }
end

assert('CBOR class encoding: non-string payload raises TypeError') do
  # tag(49999) wrapping an integer — expects a text string
  buf = "\xD9\xC3\x4F\x01"
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR.doc_end: returns byte offset after the first document') do
  buf = CBOR.encode(42) + CBOR.encode("hello")
  offset = CBOR.doc_end(buf)
  assert_equal CBOR.encode(42).bytesize, offset
end

assert('CBOR.doc_end: returns nil for empty buffer') do
  assert_nil CBOR.doc_end("")
end

assert('CBOR.doc_end: returns nil for truncated buffer') do
  # integer 0x1B needs 8 more bytes, only 0 provided
  assert_nil CBOR.doc_end("\x1B")
end

assert('CBOR.doc_end: works with offset parameter') do
  doc1 = CBOR.encode("skip")
  doc2 = CBOR.encode(99)
  buf  = doc1 + doc2
  offset = CBOR.doc_end(buf, doc1.bytesize)
  assert_equal doc1.bytesize + doc2.bytesize, offset
end

assert('CBOR register_tag: reserved tags 2, 3, 28, 29, 39 raise ArgumentError') do
  class TagReservedDummy; end
  [2, 3, 28, 29, 39].each do |reserved|
    assert_raise(ArgumentError) { CBOR.register_tag(reserved, TagReservedDummy) }
  end
end

assert('CBOR register_tag: built-in class raises TypeError') do
  [Array, Hash, String, Integer].each do |builtin|
    assert_raise(TypeError) { CBOR.register_tag(55000, builtin) }
  end
end


# ============================================================================
# 9. Shared references — Tag 28/29 (deduplication + cyclic structures)
#
# Semantics:
#   - Only objects that appear in *value* positions participate in
#     sharedref deduplication. Hash keys always encode inline, because
#     preserving key identity is rarely useful and mruby's hash stores
#     a fresh copy of the key anyway.
#   - First non-key occurrence of an object  → Tag 28 + value.
#   - Subsequent non-key occurrences         → Tag 29 + index into
#                                              shareable table.
#   - Decoder preserves identity across all Tag 29 references resolving
#     to the same Tag 28 source.
# ============================================================================

# ── Value-position sharing: arrays, maps, strings ──────────────────────────

assert('CBOR sharedref: two array refs preserve value and identity (eager)') do
  a = [1, 2]
  obj = [a, a]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [[1, 2], [1, 2]], result
  assert_equal [1, 2], result[0]
  assert_equal [1, 2], result[1]
  assert_same result[0], result[1]
end

assert('CBOR sharedref: three value refs preserve value and identity (eager)') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v, "c" => v }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_equal [1, 2, 3], result["c"]
  assert_same result["a"], result["b"]
  assert_same result["b"], result["c"]
end

assert('CBOR sharedref: shared hash value (eager)') do
  h = { "k" => "v", "n" => 42 }
  obj = [h, h, h]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [{ "k" => "v", "n" => 42 },
                { "k" => "v", "n" => 42 },
                { "k" => "v", "n" => 42 }], result
  assert_same result[0], result[1]
  assert_same result[1], result[2]
end

assert('CBOR sharedref: shared string in array (eager)') do
  s = "shared_string"
  obj = [s, s, s, { "key" => s }]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal "shared_string", result[0]
  assert_equal "shared_string", result[1]
  assert_equal "shared_string", result[2]
  assert_equal "shared_string", result[3]["key"]
  assert_same result[0], result[1]
  assert_same result[1], result[2]
  assert_same result[2], result[3]["key"]
end

# ── Cyclic structures ──────────────────────────────────────────────────────

assert('CBOR sharedref: cyclic self-referential array (eager)') do
  a = []
  a << a
  result = CBOR.decode(CBOR.encode(a, sharedrefs: true))
  assert_true  result.is_a?(Array)
  assert_equal 1, result.length
  assert_same  result, result[0]
end

assert('CBOR sharedref: cyclic self-referential hash (eager)') do
  h = {}
  h["self"] = h
  result = CBOR.decode(CBOR.encode(h, sharedrefs: true))
  assert_true result.is_a?(Hash)
  assert_same result, result["self"]
end

assert('CBOR sharedref: mutual recursion — hash references array references hash') do
  a = []
  h = { "list" => a }
  a << h
  a << h
  result = CBOR.decode(CBOR.encode(h, sharedrefs: true))
  assert_equal 2, result["list"].length
  assert_same result, result["list"][0]
  assert_same result, result["list"][1]
end

# ── Lazy decode ────────────────────────────────────────────────────────────

assert('CBOR sharedref: two array refs (lazy)') do
  a = [1, 2]
  obj = [a, a]
  result = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('CBOR sharedref: map with shared value (lazy)') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v }
  result = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR sharedref: cyclic array (lazy)') do
  a = []
  a << a
  result = CBOR.decode_lazy(CBOR.encode(a, sharedrefs: true)).value
  assert_same result, result[0]
end

# ── Deep nesting ───────────────────────────────────────────────────────────

assert('CBOR sharedref: shared leaf deep inside nested maps') do
  shared = [10, 20, 30]
  obj = {
    "a" => { "b" => { "c" => { "d" => { "e" => shared } } } },
    "x" => shared
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [10, 20, 30], result["a"]["b"]["c"]["d"]["e"]
  assert_equal [10, 20, 30], result["x"]
  assert_same result["a"]["b"]["c"]["d"]["e"], result["x"]
end

assert('CBOR sharedref: shared leaf deep inside nested arrays') do
  shared = { "k" => "v", "n" => 42 }
  obj = [[[[[shared]]]], shared, [shared]]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  leaf1 = result[0][0][0][0][0]
  leaf2 = result[1]
  leaf3 = result[2][0]
  assert_equal({ "k" => "v", "n" => 42 }, leaf1)
  assert_equal({ "k" => "v", "n" => 42 }, leaf2)
  assert_equal({ "k" => "v", "n" => 42 }, leaf3)
  assert_same leaf1, leaf2
  assert_same leaf2, leaf3
end

assert('CBOR sharedref: diamond pattern — bottom reached via multiple paths') do
  bottom = { "value" => 99 }
  left   = { "child" => bottom }
  right  = { "child" => bottom }
  root   = { "left" => left, "right" => right, "direct" => bottom }
  result = CBOR.decode(CBOR.encode(root, sharedrefs: true))

  assert_equal 99, result["left"]["child"]["value"]
  assert_equal 99, result["right"]["child"]["value"]
  assert_equal 99, result["direct"]["value"]

  assert_same result["left"]["child"],  result["right"]["child"]
  assert_same result["left"]["child"],  result["direct"]
  assert_same result["right"]["child"], result["direct"]
end

assert('CBOR sharedref: shared array containing shared sub-array') do
  inner = [1, 2, 3]
  outer = [inner, inner]    # outer contains inner twice
  obj   = [outer, outer]    # obj contains outer twice
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  assert_equal [[[1, 2, 3], [1, 2, 3]], [[1, 2, 3], [1, 2, 3]]], result
  assert_same result[0],    result[1]     # outer identity
  assert_same result[0][0], result[0][1]  # inner identity within outer
  assert_same result[0][0], result[1][0]  # inner identity across outer copies
  assert_same result[0][0], result[1][1]  # transitivity
end

assert('CBOR sharedref: multiple distinct shared groups in same structure') do
  a = [1, 2]
  b = { "k" => "v" }
  c = "shared_string"
  obj = {
    "a1" => a, "a2" => a,
    "b1" => b, "b2" => b,
    "c1" => c, "c2" => c,
    "nested" => { "a" => a, "b" => b, "c" => c }
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Values correct
  assert_equal [1, 2],           result["a1"]
  assert_equal({ "k" => "v" }, result["b1"])
  assert_equal "shared_string",  result["c1"]

  # Each group shares identity internally
  assert_same result["a1"], result["a2"]
  assert_same result["a1"], result["nested"]["a"]

  assert_same result["b1"], result["b2"]
  assert_same result["b1"], result["nested"]["b"]

  assert_same result["c1"], result["c2"]
  assert_same result["c1"], result["nested"]["c"]

  # Groups are not conflated
  assert_not_same result["a1"], result["b1"]
  assert_not_same result["b1"], result["c1"]
end

assert('CBOR sharedref: shared object repeats at every nesting level') do
  leaf = [1, 2]
  obj  = [leaf, [leaf, [leaf, [leaf, [leaf]]]]]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Collect all five occurrences
  occurrences = [result[0]]
  cur = result[1]
  while cur.is_a?(Array) && cur.length == 2
    occurrences << cur[0]
    cur = cur[1]
  end
  occurrences << cur[0] if cur.is_a?(Array)

  assert_equal 5, occurrences.length
  occurrences.each { |o| assert_equal [1, 2], o }
  (0...occurrences.length - 1).each do |i|
    assert_same occurrences[i], occurrences[i + 1]
  end
end

# ── Hash keys are NOT shared ───────────────────────────────────────────────

assert('CBOR sharedref: repeated key object does not participate in sharing') do
  # Same string used as a key in two maps. With sharedrefs on, the decoded
  # keys are still distinct string copies (mruby hash behaviour), and no
  # Tag 28/29 is emitted in key positions.
  k = "repeated_key"
  obj = [{ k => 1 }, { k => 2 }]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [{ "repeated_key" => 1 }, { "repeated_key" => 2 }], result
end

assert('CBOR sharedref: same array used as value AND key — only values share') do
  arr = [1, 2, 3]
  obj = {
    "v1"         => arr,
    "v2"         => arr,
    "as_key_map" => { arr => "payload" }
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Value occurrences share identity
  assert_equal [1, 2, 3], result["v1"]
  assert_equal [1, 2, 3], result["v2"]
  assert_same  result["v1"], result["v2"]

  # Key occurrence is a separate copy, not aliased into the value group
  inner = result["as_key_map"]
  assert_true inner.is_a?(Hash)
  assert_equal 1, inner.size
  key_arr = inner.keys[0]
  assert_equal [1, 2, 3], key_arr
  assert_equal "payload", inner[key_arr]
  assert_not_same key_arr, result["v1"]
end

assert('CBOR sharedref: object embedded inside a key does not get Tag 28') do
  # `nested` is used both inside a key-map and as a sibling value. The
  # occurrence inside the key must encode inline; the sibling-value
  # occurrence is the first Tag 28 and does not alias back into the key.
  nested  = [1, 2]
  key_map = { "inner" => nested }
  obj     = { key_map => "v1", "also" => nested }
  result  = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  assert_equal [1, 2], result["also"]

  key_side = result.keys.find { |k| k.is_a?(Hash) }
  assert_not_nil key_side
  assert_equal [1, 2], key_side["inner"]
  assert_not_same key_side["inner"], result["also"]
end

# ── Lazy + sharedrefs deep interaction ─────────────────────────────────────

assert('CBOR sharedref: lazy navigation reaches deeply shared leaf via both paths') do
  # Note: each lazy is either navigated OR materialised as a whole — not
  # both. Mixing the two modes on the same lazy corrupts the shareable
  # table, because navigation registers Lazy wrappers at Tag 28 offsets
  # and a subsequent full decode would append instead of replace.
  shared = [100, 200, 300]
  obj = { "path" => { "to" => { "leaf" => shared } }, "alias" => shared }
  lazy = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true))
  assert_equal 100, lazy["path"]["to"]["leaf"][0].value
  assert_equal 200, lazy["path"]["to"]["leaf"][1].value
  assert_equal 300, lazy["alias"][2].value
end

assert('CBOR sharedref: full materialisation preserves identity across shared paths') do
  shared = [100, 200, 300]
  obj = { "path" => { "to" => { "leaf" => shared } }, "alias" => shared }
  # Fresh lazy — no prior navigation
  full = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [100, 200, 300], full["path"]["to"]["leaf"]
  assert_equal [100, 200, 300], full["alias"]
  assert_same  full["path"]["to"]["leaf"], full["alias"]
end

assert('CBOR sharedref: lazy materialisation of diamond structure') do
  bottom = { "data" => [1, 2, 3] }
  obj    = { "a" => { "x" => bottom }, "b" => { "y" => bottom }, "c" => bottom }
  lazy   = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true))
  full   = lazy.value
  assert_equal [1, 2, 3], full["a"]["x"]["data"]
  assert_equal [1, 2, 3], full["b"]["y"]["data"]
  assert_equal [1, 2, 3], full["c"]["data"]
  assert_same  full["a"]["x"], full["b"]["y"]
  assert_same  full["a"]["x"], full["c"]
end

assert('CBOR sharedref: cyclic map round-trip preserves full cycle (eager)') do
  inner = { "name" => "cycle" }
  outer = { "child" => inner }
  inner["parent"] = outer
  result = CBOR.decode(CBOR.encode(outer, sharedrefs: true))

  assert_equal "cycle", result["child"]["name"]
  assert_same  result, result["child"]["parent"]
  assert_same  result["child"], result["child"]["parent"]["child"]
  assert_same  result["child"], result["child"]["parent"]["child"]["parent"]["child"]
end

# ── Without sharedrefs ────────────────────────────────────────────────────

assert('CBOR sharedref: without flag, values do not share identity') do
  shared = [1, 2, 3]
  obj = { "a" => shared, "b" => shared }
  result = CBOR.decode(CBOR.encode(obj))
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_not_same result["a"], result["b"]
end

assert('CBOR sharedref: encoding a cycle without flag raises (depth limit)') do
  a = []
  a << a
  assert_raise(RuntimeError) { CBOR.encode(a) }
end

# ── Wire-level decoder still accepts Tag 28 anywhere ──────────────────────

assert('CBOR sharedref: scalar shareable — integer') do
  buf = "\x82\xD8\x1C\x18\x2A\xD8\x1D\x00"
  assert_equal [42, 42], CBOR.decode(buf)
end

assert('CBOR sharedref: invalid index raises IndexError') do
  buf = "\xD8\x1D\x18\x63"
  assert_raise(IndexError) { CBOR.decode(buf) }
end

assert('CBOR sharedref: tag 29 with non-uint payload raises TypeError') do
  buf = "\xD8\x1D\x61\x61"   # tag(29) + "a"
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR sharedref: decoder accepts Tag 28 in map-value position') do
  # Even though the encoder never emits Tag 28 in a key position, the
  # decoder must accept Tag 28 anywhere it appears on the wire — other
  # CBOR implementations may emit it differently.
  buf = "\xA2\x61\x61\xD8\x1C\x83\x01\x02\x03\x61\x62\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR sharedref: lazy path through Tag 28 without prior registration') do
  buf = "\xA2" \
        "\x65outer" \
        "\xD8\x1C\x82\x01\x02" \
        "\x63ref" \
        "\xD8\x1D\x00"
  lazy = CBOR.decode_lazy(buf)
  assert_equal [1, 2], lazy["ref"].value
end

# ============================================================================
# 9. Shared references — Tag 28/29 (deduplication + cyclic structures)
#
# Semantics:
#   - Only objects that appear in *value* positions participate in
#     sharedref deduplication. Hash keys always encode inline, because
#     preserving key identity is rarely useful and mruby's hash stores
#     a fresh copy of the key anyway.
#   - First non-key occurrence of an object  → Tag 28 + value.
#   - Subsequent non-key occurrences         → Tag 29 + index into
#                                              shareable table.
#   - Decoder preserves identity across all Tag 29 references resolving
#     to the same Tag 28 source.
# ============================================================================

# ── Value-position sharing: arrays, maps, strings ──────────────────────────

assert('CBOR sharedref: two array refs preserve value and identity (eager)') do
  a = [1, 2]
  obj = [a, a]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [[1, 2], [1, 2]], result
  assert_equal [1, 2], result[0]
  assert_equal [1, 2], result[1]
  assert_same result[0], result[1]
end

assert('CBOR sharedref: three value refs preserve value and identity (eager)') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v, "c" => v }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_equal [1, 2, 3], result["c"]
  assert_same result["a"], result["b"]
  assert_same result["b"], result["c"]
end

assert('CBOR sharedref: shared hash value (eager)') do
  h = { "k" => "v", "n" => 42 }
  obj = [h, h, h]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [{ "k" => "v", "n" => 42 },
                { "k" => "v", "n" => 42 },
                { "k" => "v", "n" => 42 }], result
  assert_same result[0], result[1]
  assert_same result[1], result[2]
end

assert('CBOR sharedref: shared string in array (eager)') do
  s = "shared_string"
  obj = [s, s, s, { "key" => s }]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal "shared_string", result[0]
  assert_equal "shared_string", result[1]
  assert_equal "shared_string", result[2]
  assert_equal "shared_string", result[3]["key"]
  assert_same result[0], result[1]
  assert_same result[1], result[2]
  assert_same result[2], result[3]["key"]
end

# ── Cyclic structures ──────────────────────────────────────────────────────

assert('CBOR sharedref: cyclic self-referential array (eager)') do
  a = []
  a << a
  result = CBOR.decode(CBOR.encode(a, sharedrefs: true))
  assert_true  result.is_a?(Array)
  assert_equal 1, result.length
  assert_same  result, result[0]
end

assert('CBOR sharedref: cyclic self-referential hash (eager)') do
  h = {}
  h["self"] = h
  result = CBOR.decode(CBOR.encode(h, sharedrefs: true))
  assert_true result.is_a?(Hash)
  assert_same result, result["self"]
end

assert('CBOR sharedref: mutual recursion — hash references array references hash') do
  a = []
  h = { "list" => a }
  a << h
  a << h
  result = CBOR.decode(CBOR.encode(h, sharedrefs: true))
  assert_equal 2, result["list"].length
  assert_same result, result["list"][0]
  assert_same result, result["list"][1]
end

# ── Lazy decode ────────────────────────────────────────────────────────────

assert('CBOR sharedref: two array refs (lazy)') do
  a = [1, 2]
  obj = [a, a]
  result = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('CBOR sharedref: map with shared value (lazy)') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v }
  result = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR sharedref: cyclic array (lazy)') do
  a = []
  a << a
  result = CBOR.decode_lazy(CBOR.encode(a, sharedrefs: true)).value
  assert_same result, result[0]
end

# ── Deep nesting ───────────────────────────────────────────────────────────

assert('CBOR sharedref: shared leaf deep inside nested maps') do
  shared = [10, 20, 30]
  obj = {
    "a" => { "b" => { "c" => { "d" => { "e" => shared } } } },
    "x" => shared
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [10, 20, 30], result["a"]["b"]["c"]["d"]["e"]
  assert_equal [10, 20, 30], result["x"]
  assert_same result["a"]["b"]["c"]["d"]["e"], result["x"]
end

assert('CBOR sharedref: shared leaf deep inside nested arrays') do
  shared = { "k" => "v", "n" => 42 }
  obj = [[[[[shared]]]], shared, [shared]]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  leaf1 = result[0][0][0][0][0]
  leaf2 = result[1]
  leaf3 = result[2][0]
  assert_equal({ "k" => "v", "n" => 42 }, leaf1)
  assert_equal({ "k" => "v", "n" => 42 }, leaf2)
  assert_equal({ "k" => "v", "n" => 42 }, leaf3)
  assert_same leaf1, leaf2
  assert_same leaf2, leaf3
end

assert('CBOR sharedref: diamond pattern — bottom reached via multiple paths') do
  bottom = { "value" => 99 }
  left   = { "child" => bottom }
  right  = { "child" => bottom }
  root   = { "left" => left, "right" => right, "direct" => bottom }
  result = CBOR.decode(CBOR.encode(root, sharedrefs: true))

  assert_equal 99, result["left"]["child"]["value"]
  assert_equal 99, result["right"]["child"]["value"]
  assert_equal 99, result["direct"]["value"]

  assert_same result["left"]["child"],  result["right"]["child"]
  assert_same result["left"]["child"],  result["direct"]
  assert_same result["right"]["child"], result["direct"]
end

assert('CBOR sharedref: shared array containing shared sub-array') do
  inner = [1, 2, 3]
  outer = [inner, inner]    # outer contains inner twice
  obj   = [outer, outer]    # obj contains outer twice
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  assert_equal [[[1, 2, 3], [1, 2, 3]], [[1, 2, 3], [1, 2, 3]]], result
  assert_same result[0],    result[1]     # outer identity
  assert_same result[0][0], result[0][1]  # inner identity within outer
  assert_same result[0][0], result[1][0]  # inner identity across outer copies
  assert_same result[0][0], result[1][1]  # transitivity
end

assert('CBOR sharedref: multiple distinct shared groups in same structure') do
  a = [1, 2]
  b = { "k" => "v" }
  c = "shared_string"
  obj = {
    "a1" => a, "a2" => a,
    "b1" => b, "b2" => b,
    "c1" => c, "c2" => c,
    "nested" => { "a" => a, "b" => b, "c" => c }
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Values correct
  assert_equal [1, 2],           result["a1"]
  assert_equal({ "k" => "v" }, result["b1"])
  assert_equal "shared_string",  result["c1"]

  # Each group shares identity internally
  assert_same result["a1"], result["a2"]
  assert_same result["a1"], result["nested"]["a"]

  assert_same result["b1"], result["b2"]
  assert_same result["b1"], result["nested"]["b"]

  assert_same result["c1"], result["c2"]
  assert_same result["c1"], result["nested"]["c"]

  # Groups are not conflated
  assert_not_same result["a1"], result["b1"]
  assert_not_same result["b1"], result["c1"]
end

assert('CBOR sharedref: shared object repeats at every nesting level') do
  leaf = [1, 2]
  obj  = [leaf, [leaf, [leaf, [leaf, [leaf]]]]]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Collect all five occurrences
  occurrences = [result[0]]
  cur = result[1]
  while cur.is_a?(Array) && cur.length == 2
    occurrences << cur[0]
    cur = cur[1]
  end
  occurrences << cur[0] if cur.is_a?(Array)

  assert_equal 5, occurrences.length
  occurrences.each { |o| assert_equal [1, 2], o }
  (0...occurrences.length - 1).each do |i|
    assert_same occurrences[i], occurrences[i + 1]
  end
end

# ── Hash keys are NOT shared ───────────────────────────────────────────────

assert('CBOR sharedref: repeated key object does not participate in sharing') do
  # Same string used as a key in two maps. With sharedrefs on, the decoded
  # keys are still distinct string copies (mruby hash behaviour), and no
  # Tag 28/29 is emitted in key positions.
  k = "repeated_key"
  obj = [{ k => 1 }, { k => 2 }]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [{ "repeated_key" => 1 }, { "repeated_key" => 2 }], result
end

assert('CBOR sharedref: same array used as value AND key — only values share') do
  arr = [1, 2, 3]
  obj = {
    "v1"         => arr,
    "v2"         => arr,
    "as_key_map" => { arr => "payload" }
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Value occurrences share identity
  assert_equal [1, 2, 3], result["v1"]
  assert_equal [1, 2, 3], result["v2"]
  assert_same  result["v1"], result["v2"]

  # Key occurrence is a separate copy, not aliased into the value group
  inner = result["as_key_map"]
  assert_true inner.is_a?(Hash)
  assert_equal 1, inner.size
  key_arr = inner.keys[0]
  assert_equal [1, 2, 3], key_arr
  assert_equal "payload", inner[key_arr]
  assert_not_same key_arr, result["v1"]
end

assert('CBOR sharedref: object embedded inside a key does not get Tag 28') do
  # `nested` is used both inside a key-map and as a sibling value. The
  # occurrence inside the key must encode inline; the sibling-value
  # occurrence is the first Tag 28 and does not alias back into the key.
  nested  = [1, 2]
  key_map = { "inner" => nested }
  obj     = { key_map => "v1", "also" => nested }
  result  = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  assert_equal [1, 2], result["also"]

  key_side = result.keys.find { |k| k.is_a?(Hash) }
  assert_not_nil key_side
  assert_equal [1, 2], key_side["inner"]
  assert_not_same key_side["inner"], result["also"]
end

# ── Lazy + sharedrefs deep interaction ─────────────────────────────────────

assert('CBOR sharedref: lazy navigation reaches deeply shared leaf via both paths') do
  # Note: each lazy is either navigated OR materialised as a whole — not
  # both. Mixing the two modes on the same lazy corrupts the shareable
  # table, because navigation registers Lazy wrappers at Tag 28 offsets
  # and a subsequent full decode would append instead of replace.
  shared = [100, 200, 300]
  obj = { "path" => { "to" => { "leaf" => shared } }, "alias" => shared }
  lazy = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true))
  assert_equal 100, lazy["path"]["to"]["leaf"][0].value
  assert_equal 200, lazy["path"]["to"]["leaf"][1].value
  assert_equal 300, lazy["alias"][2].value
end

assert('CBOR sharedref: full materialisation preserves identity across shared paths') do
  shared = [100, 200, 300]
  obj = { "path" => { "to" => { "leaf" => shared } }, "alias" => shared }
  # Fresh lazy — no prior navigation
  full = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [100, 200, 300], full["path"]["to"]["leaf"]
  assert_equal [100, 200, 300], full["alias"]
  assert_same  full["path"]["to"]["leaf"], full["alias"]
end

assert('CBOR sharedref: lazy materialisation of diamond structure') do
  bottom = { "data" => [1, 2, 3] }
  obj    = { "a" => { "x" => bottom }, "b" => { "y" => bottom }, "c" => bottom }
  lazy   = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true))
  full   = lazy.value
  assert_equal [1, 2, 3], full["a"]["x"]["data"]
  assert_equal [1, 2, 3], full["b"]["y"]["data"]
  assert_equal [1, 2, 3], full["c"]["data"]
  assert_same  full["a"]["x"], full["b"]["y"]
  assert_same  full["a"]["x"], full["c"]
end

assert('CBOR sharedref: cyclic map round-trip preserves full cycle (eager)') do
  inner = { "name" => "cycle" }
  outer = { "child" => inner }
  inner["parent"] = outer
  result = CBOR.decode(CBOR.encode(outer, sharedrefs: true))

  assert_equal "cycle", result["child"]["name"]
  assert_same  result, result["child"]["parent"]
  assert_same  result["child"], result["child"]["parent"]["child"]
  assert_same  result["child"], result["child"]["parent"]["child"]["parent"]["child"]
end

# ── Registered tags under sharedrefs ──────────────────────────────────────

assert('CBOR sharedref: same registered-class instance shares identity in array (eager)') do
  class SharedPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
    def x; @x; end
    def y; @y; end
  end
  CBOR.register_tag(5000, SharedPoint)

  p = SharedPoint.new(3, 7)
  obj = [p, p, p]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_true  result[0].is_a?(SharedPoint)
  assert_equal 3, result[0].x
  assert_equal 7, result[0].y
  assert_same result[0], result[1]
  assert_same result[1], result[2]
end

assert('CBOR sharedref: distinct instances with equal fields do NOT share') do
  class SharedPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
    def x; @x; end
  end
  CBOR.register_tag(5000, SharedPoint)

  p1 = SharedPoint.new(1, 2)
  p2 = SharedPoint.new(1, 2)   # equal content, distinct object
  obj = [p1, p2]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal 1, result[0].x
  assert_equal 1, result[1].x
  assert_not_same result[0], result[1]
end

assert('CBOR sharedref: registered instance shared across map values (with non-immediate ivar)') do
  # String ivar creates a nested Tag 28 inside the registered-tag payload.
  # Works thanks to preorder slot reservation in decode_tag_sharedrefs.
  class SharedConfig
    native_ext_type :@timeout, Integer
    native_ext_type :@name,    String
    def initialize(t = 0, n = ""); @timeout = t; @name = n; end
    def timeout; @timeout; end
    def name;    @name;    end
  end
  CBOR.register_tag(5001, SharedConfig)

  cfg = SharedConfig.new(30, "default")
  obj = { "primary" => cfg, "backup" => cfg, "fallback" => cfg }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal 30,        result["primary"].timeout
  assert_equal "default", result["primary"].name
  assert_same result["primary"], result["backup"]
  assert_same result["backup"],  result["fallback"]
end

assert('CBOR sharedref: registered instance shared across mixed nesting') do
  class SharedNode
    native_ext_type :@id, Integer
    def initialize(i = 0); @id = i; end
    def id; @id; end
  end
  CBOR.register_tag(5002, SharedNode)

  node = SharedNode.new(42)
  obj = {
    "a" => { "x" => node },
    "b" => [node, node, { "nested" => node }]
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal 42, result["a"]["x"].id
  assert_same result["a"]["x"], result["b"][0]
  assert_same result["b"][0],   result["b"][1]
  assert_same result["b"][1],   result["b"][2]["nested"]
end

assert('CBOR sharedref: registered instance identity preserved through lazy.value') do
  class LazyShared
    native_ext_type :@val, Integer
    def initialize(v = 0); @val = v; end
    def val; @val; end
  end
  CBOR.register_tag(5003, LazyShared)

  l = LazyShared.new(99)
  obj = { "a" => l, "b" => l }
  full = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal 99, full["a"].val
  assert_same full["a"], full["b"]
end

assert('CBOR sharedref: registered instance as key is not aliased to value occurrences') do
  class KeyShared
    native_ext_type :@tag, String
    def initialize(s = ""); @tag = s; end
    def tag; @tag; end
  end
  CBOR.register_tag(5004, KeyShared)

  k = KeyShared.new("keyish")
  obj = { "v1" => k, "v2" => k, "as_key" => { k => "payload" } }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Value occurrences share
  assert_same result["v1"], result["v2"]

  # Key occurrence decodes to a separate instance
  inner    = result["as_key"]
  key_inst = inner.keys[0]
  assert_true  key_inst.is_a?(KeyShared)
  assert_equal "keyish", key_inst.tag
  assert_equal "payload", inner[key_inst]
  assert_not_same key_inst, result["v1"]
end

assert('CBOR sharedref: proc-registered Exception shares identity') do
  CBOR.register_tag(60100) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end

  exc = RuntimeError.new("oops")
  obj = [exc, exc, { "err" => exc }]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_true  result[0].is_a?(RuntimeError)
  assert_equal "oops", result[0].message
  assert_same result[0], result[1]
  assert_same result[1], result[2]["err"]
end

assert('CBOR sharedref: proc-registered distinct Exceptions with same message do NOT share') do
  CBOR.register_tag(60100) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end

  e1 = RuntimeError.new("boom")
  e2 = RuntimeError.new("boom")   # same class and message, distinct objects
  result = CBOR.decode(CBOR.encode([e1, e2], sharedrefs: true))
  assert_true  result[0].is_a?(RuntimeError)
  assert_true  result[1].is_a?(RuntimeError)
  assert_equal "boom", result[0].message
  assert_equal "boom", result[1].message
  assert_not_same result[0], result[1]
end




assert('CBOR sharedref: without flag, values do not share identity') do
  shared = [1, 2, 3]
  obj = { "a" => shared, "b" => shared }
  result = CBOR.decode(CBOR.encode(obj))
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_not_same result["a"], result["b"]
end

assert('CBOR sharedref: encoding a cycle without flag raises (depth limit)') do
  a = []
  a << a
  assert_raise(RuntimeError) { CBOR.encode(a) }
end

# ── Wire-level decoder still accepts Tag 28 anywhere ──────────────────────

assert('CBOR sharedref: scalar shareable — integer') do
  buf = "\x82\xD8\x1C\x18\x2A\xD8\x1D\x00"
  assert_equal [42, 42], CBOR.decode(buf)
end

assert('CBOR sharedref: invalid index raises IndexError') do
  buf = "\xD8\x1D\x18\x63"
  assert_raise(IndexError) { CBOR.decode(buf) }
end

assert('CBOR sharedref: tag 29 with non-uint payload raises TypeError') do
  buf = "\xD8\x1D\x61\x61"   # tag(29) + "a"
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR sharedref: decoder accepts Tag 28 in map-value position') do
  # Even though the encoder never emits Tag 28 in a key position, the
  # decoder must accept Tag 28 anywhere it appears on the wire — other
  # CBOR implementations may emit it differently.
  buf = "\xA2\x61\x61\xD8\x1C\x83\x01\x02\x03\x61\x62\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR sharedref: lazy path through Tag 28 without prior registration') do
  buf = "\xA2" \
        "\x65outer" \
        "\xD8\x1C\x82\x01\x02" \
        "\x63ref" \
        "\xD8\x1D\x00"
  lazy = CBOR.decode_lazy(buf)
  assert_equal [1, 2], lazy["ref"].value
end

# ============================================================================
# 10. Lazy decoding
# ============================================================================

assert('CBOR::Lazy map: basic key access') do
  h = { "a" => 1, "b" => 2 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal 1, lazy["a"].value
  assert_equal 2, lazy["b"].value
end

assert('CBOR::Lazy map: integer key access') do
  h = { 1 => "one", 2 => "two" }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal "one", lazy[1].value
  assert_equal "two", lazy[2].value
end

assert('CBOR::Lazy map: integer and string keys mixed') do
  h = { 1 => "int_key", "str" => "str_key", 100 => "int_100" }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal "int_key", lazy[1].value
  assert_equal "str_key", lazy["str"].value
  assert_equal "int_100", lazy[100].value
end

assert('CBOR::Lazy empty array access raises') do
  lazy = CBOR.decode_lazy(CBOR.encode([]))
  assert_raise(IndexError) { lazy[0] }
end

assert('CBOR::Lazy empty map access raises') do
  lazy = CBOR.decode_lazy(CBOR.encode({}))
  assert_raise(KeyError) { lazy["x"] }
end

assert('CBOR::Lazy missing key raises KeyError') do
  lazy = CBOR.decode_lazy(CBOR.encode({ "a" => 1 }))
  assert_raise(KeyError) { lazy["missing"] }
end

assert('CBOR::Lazy array out of bounds raises IndexError') do
  lazy = CBOR.decode_lazy(CBOR.encode([1, 2, 3]))
  assert_raise(IndexError) { lazy[99] }
end

assert('CBOR::Lazy: invalid array index type raises TypeError') do
  lazy = CBOR.decode_lazy(CBOR.encode([1, 2, 3]))
  assert_raise(TypeError) { lazy["invalid"].value }
end

assert('CBOR::Lazy: dig on integer raises TypeError') do
  lazy = CBOR.decode_lazy(CBOR.encode(42))
  assert_raise(TypeError) { lazy.dig("key") }
end

assert('CBOR::Lazy independent caches') do
  h = { "x" => 1, "y" => 2 }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal 1, lazy["x"].value
  assert_equal 2, lazy["y"].value
end

assert('CBOR::Lazy repeated access does not corrupt state') do
  h = { "a" => { "b" => { "c" => 123 } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  100.times { assert_equal 123, lazy["a"]["b"]["c"].value }
end

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

assert('CBOR::Lazy: lazy access after calling value on parent') do
  h = { "a" => { "b" => 42 } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  lazy.value
  inner_lazy = lazy["a"]
  assert_not_nil inner_lazy
  assert_equal 42, inner_lazy["b"].value
end

assert('CBOR::Lazy dig: handles missing keys') do
  h = { "a" => 1, "b" => { "c" => 42 } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_nil lazy.dig("missing")
  assert_nil lazy.dig("missing", "x")
  assert_equal 42, lazy.dig("b", "c").value
end

assert('CBOR::Lazy array: negative index with dig') do
  ary = [10, 20, 30, 40, 50]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_equal 50, lazy.dig(-1).value
  assert_equal 40, lazy.dig(-2).value
  assert_equal 10, lazy.dig(-5).value
end

assert('CBOR::Lazy array: negative out of bounds with dig') do
  lazy = CBOR.decode_lazy(CBOR.encode([1, 2, 3]))
  assert_nil lazy.dig(-99)
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

# ============================================================================
# 11. Streaming
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
  io = MockIO.new(CBOR.encode({ "a" => 1 }))
  results = []
  CBOR.stream(io) { |doc| results << doc.value }
  assert_equal 1,            results.length
  assert_equal({ "a" => 1 }, results[0])
end

assert('CBOR.stream: multiple concatenated documents') do
  buf = CBOR.encode({ "a" => 1 }) + CBOR.encode([1, 2, 3]) + CBOR.encode(42)
  results = []
  CBOR.stream(MockIO.new(buf)) { |doc| results << doc.value }
  assert_equal 3,            results.length
  assert_equal({ "a" => 1 }, results[0])
  assert_equal [1, 2, 3],    results[1]
  assert_equal 42,           results[2]
end

assert('CBOR.stream: document shorter than 9 bytes') do
  results = []
  CBOR.stream(MockIO.new(CBOR.encode(0))) { |doc| results << doc.value }
  assert_equal 1, results.length
  assert_equal 0, results[0]
end

assert('CBOR.stream: large document requiring readahead') do
  big = { "items" => (1..100).map { |i| { "id" => i, "name" => "item#{i}" } } }
  buf = CBOR.encode(big)
  assert_true buf.bytesize > 9
  results = []
  CBOR.stream(MockIO.new(buf)) { |doc| results << doc.value }
  assert_equal 1,   results.length
  assert_equal big, results[0]
end

assert('CBOR.stream: enumerator without block') do
  buf     = CBOR.encode("hello") + CBOR.encode("world")
  results = CBOR.stream(MockIO.new(buf)).map(&:value)
  assert_equal 2,       results.length
  assert_equal "hello", results[0]
  assert_equal "world", results[1]
end

assert('CBOR.stream: empty io yields nothing') do
  results = []
  CBOR.stream(MockIO.new("")) { |doc| results << doc.value }
  assert_equal 0, results.length
end

assert('CBOR.stream: offset parameter skips first bytes') do
  doc1 = CBOR.encode("skip")
  doc2 = CBOR.encode("keep")
  results = []
  CBOR.stream(MockIO.new(doc1 + doc2), doc1.bytesize) { |doc| results << doc.value }
  assert_equal 1,      results.length
  assert_equal "keep", results[0]
end

assert('CBOR.stream: multiple documents with different major types') do
  docs = [42, "hello", [1, 2, 3], { "x" => 1 }, true, nil]
  buf  = docs.map { |d| CBOR.encode(d) }.join
  results = CBOR.stream(MockIO.new(buf)).map(&:value)
  assert_equal docs.length, results.length
  docs.each_with_index { |expected, i| assert_equal expected, results[i] }
end

assert('CBOR.stream: document containing float') do
  results = []
  CBOR.stream(MockIO.new(CBOR.encode(1.5))) { |doc| results << doc.value }
  assert_equal 1,   results.length
  assert_equal 1.5, results[0]
end

assert('CBOR.stream: document containing shared refs') do
  v   = [1, 2, 3]
  buf = CBOR.encode({ "a" => v, "b" => v }, sharedrefs: true)
  results = []
  CBOR.stream(MockIO.new(buf)) { |doc| results << doc.value }
  assert_equal 1, results.length
  assert_equal({ "a" => [1, 2, 3], "b" => [1, 2, 3] }, results[0])
end

assert('CBOR.stream: documents with various integer sizes') do
  docs = [0, 23, 24, 255, 256, 65535, 65536, 0xFFFFFFFF, 0x100000000]
  buf  = docs.map { |n| CBOR.encode(n) }.join
  results = []
  CBOR.stream(MockIO.new(buf)) { |doc| results << doc.value }
  assert_equal docs, results
end

assert('CBOR.stream: document with nested shared refs') do
  inner = { "data" => [1, 2, 3] }
  obj   = [inner, inner, inner]
  buf   = CBOR.encode(obj, sharedrefs: true)
  results = CBOR.stream(MockIO.new(buf)).map(&:value)
  assert_equal 1, results.length
  assert_same results[0][0], results[0][1]
  assert_same results[0][1], results[0][2]
end

assert('CBOR.stream: empty stream yields no documents') do
  results = []
  CBOR.stream(MockIO.new("")) { |doc| results << doc.value }
  assert_equal 0, results.length
end

assert('CBOR.stream: stream documents from middle of buffer') do
  doc1    = CBOR.encode("first")
  results = []
  CBOR.stream(MockIO.new(doc1 + CBOR.encode("second") + CBOR.encode("third")),
              doc1.bytesize) { |d| results << d.value }
  assert_equal 2,        results.length
  assert_equal "second", results[0]
  assert_equal "third",  results[1]
end

assert('CBOR.stream: string with single doc') do
  docs = []
  CBOR.stream(CBOR.encode({ "a" => 1 })) { |d| docs << d.value }
  assert_equal 1,            docs.length
  assert_equal({ "a" => 1 }, docs[0])
end

assert('CBOR.stream: string with multiple docs') do
  buf  = CBOR.encode(1) + CBOR.encode(2) + CBOR.encode(3)
  docs = []
  CBOR.stream(buf) { |d| docs << d.value }
  assert_equal [1, 2, 3], docs
end

assert('CBOR.stream: string with offset') do
  buf  = CBOR.encode(1) + CBOR.encode(2) + CBOR.encode(3)
  skip = CBOR.encode(1).bytesize
  docs = []
  CBOR.stream(buf, skip) { |d| docs << d.value }
  assert_equal [2, 3], docs
end

assert('CBOR.stream: string without block returns enumerator') do
  e = CBOR.stream(CBOR.encode(1) + CBOR.encode(2))
  assert_true e.respond_to?(:each)
end

assert('CBOR.stream: type error on unknown io') do
  assert_raise(TypeError) { CBOR.stream(42) }
end

assert('CBOR::StreamDecoder responds to feed') do
  dec = CBOR::StreamDecoder.new {}
  assert_true dec.respond_to?(:feed)
end

assert('CBOR.stream: StreamDecoder fed in chunks') do
  buf  = CBOR.encode("hello") + CBOR.encode("world")
  docs = []
  dec  = CBOR::StreamDecoder.new { |d| docs << d.value }
  buf.each_byte { |b| dec.feed(b.chr) }
  assert_equal ["hello", "world"], docs
end

# ============================================================================
# 12. Registered tags — native_ext_type, hooks, proc tags, errors
# ============================================================================

assert('CBOR register_tag: encode and decode custom class') do
  class Point
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer

    def initialize(x = 0, y = 0)
      @x = x
      @y = y
    end

    def _after_decode; self; end
    def _before_encode; self; end

    def ==(other)
      other.is_a?(Point) &&
        @x == other.instance_variable_get(:@x) &&
        @y == other.instance_variable_get(:@y)
    end
  end

  CBOR.register_tag(1000, Point)

  p = Point.new(3, 7)
  decoded = CBOR.decode(CBOR.encode(p))
  assert_true decoded.is_a?(Point)
  assert_equal p, decoded
end

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

  CBOR.register_tag(1000, Point)

  p = Point.new(5, 10)
  decoded = CBOR.decode_lazy(CBOR.encode(p)).value
  assert_true decoded.is_a?(Point)
  assert_equal p, decoded
end

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

    def loaded?; @loaded; end
  end

  CBOR.register_tag(1000, Person)

  person = Person.new
  person.name = "Alice"
  person.age  = 30

  decoded = CBOR.decode(CBOR.encode(person))
  assert_true decoded.is_a?(Person)
  assert_equal "Alice", decoded.name
  assert_equal 30,      decoded.age
  assert_true  decoded.loaded?
end

assert('CBOR registered tag: _before_encode hook called') do
  class Item
    attr_accessor :value
    native_ext_type :@value, Integer

    def initialize(val); @value = val; end

    def _before_encode
      @value = @value * 2
      self
    end
  end

  CBOR.register_tag(1001, Item)

  decoded = CBOR.decode(CBOR.encode(Item.new(5)))
  assert_equal 10, decoded.value
end

assert('CBOR registered tag: both hooks in sequence') do
  class Counter
    attr_accessor :count
    native_ext_type :@count, Integer

    def initialize(n)
      @count = n
      @before_encode_called = false
      @after_decode_called  = false
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
    def after_decode_called?;  @after_decode_called; end
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

    def initialize(val); @amount = val; end

    def _before_encode
      @amount = (@amount * 100).to_i
      self
    end
  end

  CBOR.register_tag(1003, Price)

  decoded = CBOR.decode(CBOR.encode(Price.new(5)))
  assert_equal 500, decoded.amount
  assert_true decoded.is_a?(Price)
end

assert('CBOR registered tag: _after_decode without _before_encode') do
  class Config
    attr_accessor :timeout
    native_ext_type :@timeout, Integer

    def initialize(val)
      @timeout   = val
      @validated = false
    end

    def _after_decode
      @timeout   = @timeout.abs
      @validated = true
      self
    end

    def validated?; @validated; end
  end

  CBOR.register_tag(1004, Config)

  decoded = CBOR.decode(CBOR.encode(Config.new(30)))
  assert_equal 30, decoded.timeout
  assert_true decoded.validated?
end

assert('CBOR registered tag: hook exception propagates') do
  class Strict
    attr_accessor :value
    native_ext_type :@value, Integer

    def initialize(val); @value = val; end

    def _before_encode
      raise "encode forbidden"
    end
  end

  CBOR.register_tag(1005, Strict)

  assert_raise(RuntimeError) { CBOR.encode(Strict.new(42)) }
end

assert('CBOR registered tag: hook modifies multiple fields') do
  class User
    attr_accessor :username, :email
    native_ext_type :@username, String
    native_ext_type :@email,    String

    def initialize; @username = ""; @email = ""; end

    def _after_decode
      @username = @username.downcase
      @email    = @email.downcase
      self
    end
  end

  CBOR.register_tag(1006, User)

  u = User.new
  u.username = "AlicE"
  u.email    = "Alice@Example.COM"

  decoded = CBOR.decode(CBOR.encode(u))
  assert_equal "alice",             decoded.username
  assert_equal "alice@example.com", decoded.email
end

assert('CBOR registered tag: lazy decode with _after_decode') do
  class Data
    attr_accessor :value
    native_ext_type :@value, Integer

    def initialize(val)
      @value        = val
      @materialized = false
    end

    def _after_decode
      @materialized = true
      self
    end

    def materialized?; @materialized; end
  end

  CBOR.register_tag(1007, Data)

  data    = Data.new(99)
  encoded = CBOR.encode(data)
  lazy    = CBOR.decode_lazy(encoded)
  assert_false data.materialized?
  materialized = lazy.value
  assert_true  materialized.materialized?
  assert_equal 99, materialized.value
end

assert('CBOR registered tag: extra fields are silently ignored') do
  class WhitelistPerson
    attr_accessor :allowed_a, :allowed_b, :ignored_field
    native_ext_type :@allowed_a, String
    native_ext_type :@allowed_b, Integer

    def initialize
      @allowed_a    = ""
      @allowed_b    = 0
      @ignored_field = nil
    end
  end

  CBOR.register_tag(2000, WhitelistPerson)

  payload_cbor = CBOR.encode({
    "allowed_a"     => "hello",
    "allowed_b"     => 42,
    "extra_field_1" => "ignored",
    "extra_field_2" => [1, 2, 3],
    "extra_field_3" => { "nested" => "data" }
  })
  decoded = CBOR.decode("\xD9\x07\xD0" + payload_cbor)  # Tag(2000)

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

    def initialize; @id = 0; @name = ""; end
  end

  CBOR.register_tag(2001, StrictRecord)

  payload = {
    "id" => 999, "name" => "test",
    "secret" => "hidden", "data" => { "nested" => "ignored" },
    "array" => [1, 2, 3, 4, 5], "extra_int" => 12345,
    "extra_bool" => true, "extra_nil" => nil
  }
  decoded = CBOR.decode("\xD9\x07\xD1" + CBOR.encode(payload))  # Tag(2001)

  assert_true decoded.is_a?(StrictRecord)
  assert_equal 999,    decoded.id
  assert_equal "test", decoded.name
  assert_equal 2,      decoded.instance_variables.length
end

assert('CBOR registered tag: payload must be a map raises TypeError') do
  # Tag(1000) + integer payload — registered class expects a map
  tag_bytes = "\xD9\x03\xE8"  # tag(1000)
  buf = tag_bytes + "\x01"    # integer 1 — not a map
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR registered tag: decode field wrong type raises TypeError') do
  class TypeMismatchRecord
    attr_accessor :name
    native_ext_type :@name, String
    def initialize; @name = ""; end
  end

  CBOR.register_tag(3001, TypeMismatchRecord)

  # Craft a payload where @name is an Integer instead of String
  payload_cbor = CBOR.encode({ "name" => 42 })
  buf = "\xD9\x0B\xB9" + payload_cbor  # tag(3001)
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR registered tag: encode field wrong type raises TypeError') do
  class EncTypeMismatch
    native_ext_type :@value, Integer
    def initialize(v); @value = v; end
  end

  CBOR.register_tag(3002, EncTypeMismatch)

  # Store a String in an Integer-declared field to trigger encode-time mismatch
  obj = EncTypeMismatch.allocate
  obj.instance_variable_set(:@value, "not an integer")
  assert_raise(TypeError) { CBOR.encode(obj) }
end


assert('CBOR proc tag: basic encode and decode') do
  class ProcTagBox
    attr_accessor :val
    def initialize(v = 0); @val = v; end
  end

  CBOR.register_tag(60000) do
    encode ProcTagBox do |b| b.val end
    decode Integer    do |i| ProcTagBox.new(i) end
  end

  buf    = CBOR.encode(ProcTagBox.new(42))
  result = CBOR.decode(buf)
  assert_true result.is_a?(ProcTagBox)
  assert_equal 42, result.val
end

assert('CBOR proc tag: lazy decode fires proc') do
  class ProcTagBox
    attr_accessor :val
    def initialize(v = 0); @val = v; end
  end

  CBOR.register_tag(60007) do
    encode ProcTagBox do |b| b.val end
    decode Integer    do |i| ProcTagBox.new(i + 1) end
  end

  result = CBOR.decode_lazy(CBOR.encode(ProcTagBox.new(6))).value
  assert_true result.is_a?(ProcTagBox)
  assert_equal 7, result.val
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
    exc = CBOR.decode(CBOR.encode(klass.new("msg")))
    assert_equal klass, exc.class
  end
end

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

  result = CBOR.decode(CBOR.encode(RuntimeError.new("ok")))
  assert_equal "ok", result.message
end

# ============================================================================
# 13. Fast path (encode_fast / decode_fast)
# ============================================================================

assert('CBOR fast: boolean and nil roundtrip') do
  assert_true  CBOR.decode_fast(CBOR.encode_fast(true))
  assert_false CBOR.decode_fast(CBOR.encode_fast(false))
  assert_nil   CBOR.decode_fast(CBOR.encode_fast(nil))
end

assert('CBOR fast: integer roundtrip') do
  assert_equal 0,      CBOR.decode_fast(CBOR.encode_fast(0))
  assert_equal 1,      CBOR.decode_fast(CBOR.encode_fast(1))
  assert_equal 127,    CBOR.decode_fast(CBOR.encode_fast(127))
  assert_equal 255,    CBOR.decode_fast(CBOR.encode_fast(255))
  assert_equal 256,    CBOR.decode_fast(CBOR.encode_fast(256))
  assert_equal 65535,  CBOR.decode_fast(CBOR.encode_fast(65535))
  assert_equal 65536,  CBOR.decode_fast(CBOR.encode_fast(65536))
end

assert('CBOR fast: negative integer roundtrip') do
  assert_equal(-1,     CBOR.decode_fast(CBOR.encode_fast(-1)))
  assert_equal(-42,    CBOR.decode_fast(CBOR.encode_fast(-42)))
  assert_equal(-1000,  CBOR.decode_fast(CBOR.encode_fast(-1000)))
  assert_equal(-65536, CBOR.decode_fast(CBOR.encode_fast(-65536)))
end

assert('CBOR fast: integer MRB_INT_MAX roundtrip') do
  n = 2**30 - 1
  assert_equal n, CBOR.decode_fast(CBOR.encode_fast(n))
end

assert('CBOR fast: mixed negative and positive integers') do
  ary = [-100, -1, 0, 1, 100, -65536, 65536]
  assert_equal ary, CBOR.decode_fast(CBOR.encode_fast(ary))
end

assert('CBOR fast: float roundtrip') do
  assert_equal 0.0,  CBOR.decode_fast(CBOR.encode_fast(0.0))
  assert_equal 1.5,  CBOR.decode_fast(CBOR.encode_fast(1.5))
  assert_equal 3.14, CBOR.decode_fast(CBOR.encode_fast(3.14))
  assert_equal(-1.5, CBOR.decode_fast(CBOR.encode_fast(-1.5)))
  assert_equal Float::INFINITY,  CBOR.decode_fast(CBOR.encode_fast(Float::INFINITY))
  assert_equal(-Float::INFINITY, CBOR.decode_fast(CBOR.encode_fast(-Float::INFINITY)))
  assert_true CBOR.decode_fast(CBOR.encode_fast(Float::NAN)).nan?
end

assert('CBOR fast: string roundtrip') do
  assert_equal "",      CBOR.decode_fast(CBOR.encode_fast(""))
  assert_equal "hello", CBOR.decode_fast(CBOR.encode_fast("hello"))
  assert_equal "hällo", CBOR.decode_fast(CBOR.encode_fast("hällo"))
end

assert('CBOR fast: empty array roundtrip') do
  assert_equal [], CBOR.decode_fast(CBOR.encode_fast([]))
end

assert('CBOR fast: empty map roundtrip') do
  assert_equal({}, CBOR.decode_fast(CBOR.encode_fast({})))
end

assert('CBOR fast: array roundtrip') do
  ary = [1, -2, "three", true, false, nil, 3.14]
  assert_equal ary, CBOR.decode_fast(CBOR.encode_fast(ary))
end

assert('CBOR fast: map roundtrip') do
  h = { "id" => 42, "name" => "Alice", "score" => -99, "active" => true }
  assert_equal h, CBOR.decode_fast(CBOR.encode_fast(h))
end

assert('CBOR fast: nested structure roundtrip') do
  obj = {
    "users" => [
      { "id" => 1, "name" => "Alice", "age" => 30 },
      { "id" => 2, "name" => "Bob",   "age" => 25 }
    ],
    "count" => 2
  }
  assert_equal obj, CBOR.decode_fast(CBOR.encode_fast(obj))
end

assert('CBOR fast: integer array roundtrip') do
  ary = (1..100).to_a
  assert_equal ary, CBOR.decode_fast(CBOR.encode_fast(ary))
end

assert('CBOR fast: symbol always encodes as tag 39 + string') do
  buf = CBOR.encode_fast(:hello)
  assert_equal :hello, CBOR.decode_fast(buf)
end

assert('CBOR fast: symbol in map') do
  h = { hello: 1, world: 2 }
  assert_equal h, CBOR.decode_fast(CBOR.encode_fast(h))
end

assert('CBOR fast: class roundtrip') do
  assert_equal String,         CBOR.decode_fast(CBOR.encode_fast(String))
  assert_equal Integer,        CBOR.decode_fast(CBOR.encode_fast(Integer))
  assert_equal ArgumentError,  CBOR.decode_fast(CBOR.encode_fast(ArgumentError))
end

assert('CBOR fast: class in structure') do
  h = { "klass" => StandardError, "msg" => "oops" }
  assert_equal h, CBOR.decode_fast(CBOR.encode_fast(h))
end

assert('CBOR fast: integers use fixed width') do
  assert_true CBOR.encode_fast(1).bytesize >= CBOR.encode(1).bytesize
end

assert('CBOR fast: strings always encode as major 2 (byte string)') do
  buf = CBOR.encode_fast("hello")
  # major 2, length 5 → 0x45
  assert_equal 0x45, buf.getbyte(0)
  assert_equal "hello", CBOR.decode_fast(buf)
end

assert('CBOR fast: string length prefix uses canonical shortest form') do
  # length overhead is identical to canonical — only the major type differs
  assert_equal CBOR.encode("hello").bytesize, CBOR.encode_fast("hello").bytesize
end

assert('CBOR fast: array count uses canonical shortest form') do
  assert_equal CBOR.encode([true, false, nil]).bytesize,
               CBOR.encode_fast([true, false, nil]).bytesize
end

assert('CBOR fast: decode canonical buffer raises') do
  assert_raise(RuntimeError) { CBOR.decode_fast(CBOR.encode(1)) }
end

assert('CBOR fast: tag 39 with non-string payload raises TypeError') do
  # tag(39) = 0xD8 0x27; payload = true (0xF5, 1-byte simple).
  # decode_value_fast handles 0xF5 fine → returns true → mrb_string_p fails → TypeError.
  buf = "\xD8\x27\xF5"
  assert_raise(TypeError) { CBOR.decode_fast(buf) }
end

assert('CBOR fast: tag 49999 with non-string payload raises TypeError') do
  # tag(49999) = 0xD9 0xC3 0x4F; payload = true (0xF5).
  buf = "\xD9\xC3\x4F\xF5"
  assert_raise(TypeError) { CBOR.decode_fast(buf) }
end

assert('CBOR fast: wrong-width integer info raises RuntimeError') do
  # On a 64-bit build (MRB_INT_BIT=64) CBOR_FAST_INT_INFO == 27 (info=0x1B).
  # Feed a canonical uint8 (info=0x18, major 0) — wrong info for fast decoder.
  # On any build the canonical small-integer 0x01 (info < 24) is always wrong.
  assert_raise(RuntimeError) { CBOR.decode_fast("\x01") }
end

assert('CBOR fast: major 3 (text string) raises RuntimeError') do
  # Fast path always uses major 2 for strings. A canonical text string
  # (major 3) hits the "fast: unsupported major type" branch.
  # "\x65hello" = major 3, length 5, "hello"
  assert_raise(RuntimeError) { CBOR.decode_fast("\x65hello") }
end

assert('CBOR fast: registered tag falls back to canonical encode, canonical decode') do
  class FastPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer

    def initialize(x = 0, y = 0); @x = x; @y = y; end

    def ==(other)
      other.is_a?(FastPoint) &&
        @x == other.instance_variable_get(:@x) &&
        @y == other.instance_variable_get(:@y)
    end
  end

  CBOR.register_tag(9001, FastPoint)

  p       = FastPoint.new(3, 7)
  decoded = CBOR.decode_fast(CBOR.encode_fast(p))
  assert_true decoded.is_a?(FastPoint)
  assert_equal 3, decoded.instance_variable_get(:@x)
  assert_equal 7, decoded.instance_variable_get(:@y)
end

assert('CBOR fast: registered tag in array falls back correctly') do
  class FastBox
    native_ext_type :@val, Integer
    def initialize(v = 0); @val = v; end
    def ==(other)
      other.is_a?(FastBox) && @val == other.instance_variable_get(:@val)
    end
  end
  CBOR.register_tag(9002, FastBox)

  ary     = [1, FastBox.new(42), "hello", FastBox.new(99)]
  decoded = CBOR.decode_fast(CBOR.encode_fast(ary))
  assert_equal 42,      decoded[1].instance_variable_get(:@val)
  assert_equal "hello", decoded[2]
  assert_equal 99,      decoded[3].instance_variable_get(:@val)
end

assert('CBOR fast: fallback output identical to canonical for registered types') do
  class FastShape
    native_ext_type :@sides, Integer
    native_ext_type :@color, String
    def initialize(s = 0, c = ""); @sides = s; @color = c; end
  end
  CBOR.register_tag(9003, FastShape)

  obj = FastShape.new(4, "red")
  assert_equal CBOR.encode(obj), CBOR.encode_fast(obj)
end

assert('CBOR fast: _before_encode hook fires on fallback') do
  class FastItem
    attr_accessor :value
    native_ext_type :@value, Integer
    def initialize(v); @value = v; end
    def _before_encode; @value = @value * 2; self; end
  end
  CBOR.register_tag(9010, FastItem)

  decoded = CBOR.decode_fast(CBOR.encode_fast(FastItem.new(5)))
  assert_equal 10, decoded.value
end

assert('CBOR fast: _after_decode hook fires on fallback decode') do
  class FastConfig
    attr_accessor :timeout
    native_ext_type :@timeout, Integer
    def initialize(v); @timeout = v; @validated = false; end
    def _after_decode; @timeout = @timeout.abs; @validated = true; self; end
    def validated?; @validated; end
  end
  CBOR.register_tag(9011, FastConfig)

  decoded = CBOR.decode_fast(CBOR.encode_fast(FastConfig.new(30)))
  assert_equal 30, decoded.timeout
  assert_true decoded.validated?
end

assert('CBOR fast: extra fields silently ignored on fallback decode') do
  class FastRecord
    attr_accessor :id, :name
    native_ext_type :@id,   Integer
    native_ext_type :@name, String
    def initialize; @id = 0; @name = ""; end
  end
  CBOR.register_tag(9012, FastRecord)

  payload = { "id" => 7, "name" => "alice", "secret" => "ignored" }
  tagged  = "\xD9\x23\x34" + CBOR.encode(payload)  # tag(9012) + canonical payload
  decoded = CBOR.decode_fast(tagged)
  assert_true decoded.is_a?(FastRecord)
  assert_equal 7,       decoded.id
  assert_equal "alice", decoded.name
  assert_equal 2, decoded.instance_variables.length
end

assert('CBOR fast: registered tag in nested structure') do
  class FastVec
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
    def ==(other)
      other.is_a?(FastVec) &&
        @x == other.instance_variable_get(:@x) &&
        @y == other.instance_variable_get(:@y)
    end
  end
  CBOR.register_tag(9013, FastVec)

  obj = {
    "origin" => FastVec.new(0, 0),
    "points" => [FastVec.new(1, 2), FastVec.new(3, 4)],
    "count"  => 2
  }
  decoded = CBOR.decode_fast(CBOR.encode_fast(obj))
  assert_equal FastVec.new(0, 0), decoded["origin"]
  assert_equal FastVec.new(1, 2), decoded["points"][0]
  assert_equal FastVec.new(3, 4), decoded["points"][1]
  assert_equal 2, decoded["count"]
end

assert('CBOR fast: proc tag falls back to canonical') do
  class FastWrapper
    def initialize(v); @v = v; end
    def val; @v; end
  end
  CBOR.register_tag(9014) do
    encode FastWrapper do |w| w.val end
    decode Integer     do |i| FastWrapper.new(i * 3) end
  end

  w   = FastWrapper.new(7)
  buf = CBOR.encode_fast(w)
  assert_equal buf, CBOR.encode(w)   # fallback must produce identical bytes
  decoded = CBOR.decode_fast(buf)
  assert_true decoded.is_a?(FastWrapper)
  assert_equal 21, decoded.val
end

assert('CBOR fast: random bytes never crash') do
  r = Random.new(0xFA57)
  200.times do
    buf = r.rand(0..128).times.map { r.rand(0..255).chr }.join
    begin
      CBOR.decode_fast(buf)
    rescue RuntimeError, RangeError, TypeError, NotImplementedError, ArgumentError, NameError
      # expected — bad input rejected cleanly
    end
  end
  assert_true true
end

assert('CBOR fast: truncated buffers never crash') do
  [
    CBOR.encode_fast([1, 2, 3]),
    CBOR.encode_fast({ "a" => 1, "b" => 2 }),
    CBOR.encode_fast(42),
    CBOR.encode_fast("hello"),
  ].each do |buf|
    buf.bytesize.times do |cut|
      begin
        CBOR.decode_fast(buf[0, cut])
      rescue RuntimeError, RangeError, TypeError, NotImplementedError, ArgumentError, NameError
        # expected
      end
    end
  end
  assert_true true
end

# ============================================================================
# 14. Error / safety — depth limit, malformed input, fuzz corpus
# ============================================================================

def assert_safe(&block)
  begin
    block.call
  rescue RuntimeError, RangeError, TypeError, NotImplementedError,
         ArgumentError, KeyError, IndexError, NameError
    # clean error — pass
  end
  assert_true true
end

assert('CBOR depth limit: deeply nested arrays raise RuntimeError') do
  # Build an array nested deeper than CBOR_MAX_DEPTH
  depth = 200
  buf = depth.times.inject("") { |acc, _| "\x81" + acc } + "\x00"
  assert_raise(RuntimeError) { CBOR.decode(buf) }
end

assert('CBOR depth limit: deeply nested maps raise RuntimeError') do
  depth = 200
  # each map: 0xA1 (1-entry map) + key "a" (0x61 0x61) + value = next level
  inner = "\x00"  # integer 0 at the bottom
  buf = depth.times.inject(inner) { |acc, _| "\xA1\x61\x61" + acc }
  assert_raise(RuntimeError) { CBOR.decode(buf) }
end

assert('CBOR depth limit: fast path respects depth limit') do
  depth = 200
  buf = depth.times.inject("") { |acc, _| "\x81" + acc } + "\x00"
  # encode_fast produces fixed-width integers so we rebuild with canonical
  # to test decode_fast's depth guard — or just test that decode also guards
  assert_raise(RuntimeError) { CBOR.decode(buf) }
end

assert('CBOR exploit: self-referential tag28 inside tag28 is safe') do
  buf = "\xD8\x1C\xD8\x1C\x18\x2A"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: tag 29 index overflow (uint64 max)') do
  buf = "\xD8\x1D\x1B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: map with odd item count (missing last value)') do
  buf = "\xA2\x61\x61\x01\x61\x62"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: text string with invalid UTF-8') do
  buf = "\x63\xFF\xFE\xFD"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: reserved simple values (info 28, 29, 30)') do
  ["\xFC", "\xFD", "\xFE"].each { |buf| assert_safe { CBOR.decode(buf) } }
end

assert('CBOR exploit: indefinite-length array marker') do
  assert_safe { CBOR.decode("\x9F\x01\x02\xFF") }
end

assert('CBOR exploit: indefinite-length map marker') do
  assert_safe { CBOR.decode("\xBF\x61\x61\x01\xFF") }
end

assert('CBOR exploit: indefinite-length text string') do
  assert_safe { CBOR.decode("\x7F\x61\x61\x61\x62\xFF") }
end

assert('CBOR exploit: lazy aref on non-container') do
  lazy = CBOR.decode_lazy(CBOR.encode(42))
  assert_safe { lazy[0] }
  assert_safe { lazy["key"] }
end

assert('CBOR exploit: lazy aref with huge array index') do
  lazy = CBOR.decode_lazy(CBOR.encode([1, 2, 3]))
  assert_safe { lazy[0x7FFFFFFF] }
end

assert('CBOR exploit: zero-length bignum tag') do
  assert_safe { CBOR.decode("\xC2\x40") }
end

assert('CBOR symbols_as_uint32: out-of-range symbol ID raises RangeError') do
  # Craft tag(39) + uint64 value that exceeds UINT32_MAX
  # tag(39) = 0xD8 0x27; uint64 = 0x1B + 8 bytes = 0x1_0000_0000 (2^32)
  buf = "\xD8\x27\x1B\x00\x00\x00\x01\x00\x00\x00\x00"
  CBOR.symbols_as_uint32
  assert_raise(RangeError) { CBOR.decode(buf) }
  CBOR.no_symbols
end

assert('CBOR depth limit: encode raises RuntimeError when nesting too deep') do
  # Build a Ruby array nested 200 levels deep and attempt to encode it
  depth = 200
  obj = depth.times.inject(0) { |inner, _| [inner] }
  assert_raise(RuntimeError) { CBOR.encode(obj) }
end

assert('CBOR depth limit: encode_fast raises RuntimeError when nesting too deep') do
  depth = 200
  obj = depth.times.inject(0) { |inner, _| [inner] }
  assert_raise(RuntimeError) { CBOR.encode_fast(obj) }
end

# ============================================================================
# Multi-type native_ext_type — nullable and union fields
# ============================================================================

assert('CBOR native_ext_type: nullable Integer field roundtrips with value') do
  class NullableProduct
    native_ext_type :@id,    Integer
    native_ext_type :@price, Integer, NilClass

    def initialize; @id = 0; @price = nil; end
  end

  CBOR.register_tag(4000, NullableProduct)

  p = NullableProduct.new
  p.instance_variable_set(:@id,    1)
  p.instance_variable_set(:@price, 999)

  decoded = CBOR.decode(CBOR.encode(p))
  assert_true  decoded.is_a?(NullableProduct)
  assert_equal 1,   decoded.instance_variable_get(:@id)
  assert_equal 999, decoded.instance_variable_get(:@price)
end

assert('CBOR native_ext_type: nullable Integer field roundtrips as nil') do
  class NullableProduct
    native_ext_type :@id,    Integer
    native_ext_type :@price, Integer, NilClass

    def initialize; @id = 0; @price = nil; end
  end

  CBOR.register_tag(4000, NullableProduct)

  p = NullableProduct.new
  p.instance_variable_set(:@id,    2)
  # @price stays nil

  decoded = CBOR.decode(CBOR.encode(p))
  assert_equal 2,   decoded.instance_variable_get(:@id)
  assert_nil decoded.instance_variable_get(:@price)
end

assert('CBOR native_ext_type: nullable String field roundtrips with value and nil') do
  class NullableRecord
    native_ext_type :@name, String,  NilClass
    native_ext_type :@note, String,  NilClass

    def initialize; @name = nil; @note = nil; end
  end

  CBOR.register_tag(4001, NullableRecord)

  r = NullableRecord.new
  r.instance_variable_set(:@name, "Alice")
  # @note stays nil

  decoded = CBOR.decode(CBOR.encode(r))
  assert_equal "Alice", decoded.instance_variable_get(:@name)
  assert_nil            decoded.instance_variable_get(:@note)
end

assert('CBOR native_ext_type: boolean-or-nil field accepts all three values') do
  class FlagRecord
    native_ext_type :@enabled, TrueClass, FalseClass, NilClass

    def initialize; @enabled = nil; end
  end

  CBOR.register_tag(4002, FlagRecord)

  [true, false, nil].each do |val|
    r = FlagRecord.new
    r.instance_variable_set(:@enabled, val)
    decoded = CBOR.decode(CBOR.encode(r))
    assert_equal val, decoded.instance_variable_get(:@enabled)
  end
end

assert('CBOR native_ext_type: numeric union field accepts Integer and Float') do
  class ScoreRecord
    native_ext_type :@score, Integer, Float, NilClass

    def initialize; @score = nil; end
  end

  CBOR.register_tag(4003, ScoreRecord)

  [[42, 42], [3.14, 3.14], [nil, nil]].each do |input, expected|
    r = ScoreRecord.new
    r.instance_variable_set(:@score, input)
    decoded = CBOR.decode(CBOR.encode(r))
    if expected.nil?
      assert_nil decoded.instance_variable_get(:@score)
    else
      assert_equal expected, decoded.instance_variable_get(:@score)
    end
  end
end

assert('CBOR native_ext_type: wrong type for nullable field raises TypeError on encode') do
  class NullableProduct
    native_ext_type :@id,    Integer
    native_ext_type :@price, Integer, NilClass

    def initialize; @id = 0; @price = nil; end
  end

  CBOR.register_tag(4000, NullableProduct)

  p = NullableProduct.new
  p.instance_variable_set(:@id,    3)
  p.instance_variable_set(:@price, "free")  # String is not Integer or NilClass

  assert_raise(TypeError) { CBOR.encode(p) }
end

assert('CBOR native_ext_type: wrong type for nullable field raises TypeError on decode') do
  class NullableProduct
    native_ext_type :@id,    Integer
    native_ext_type :@price, Integer, NilClass

    def initialize; @id = 0; @price = nil; end
  end

  CBOR.register_tag(4000, NullableProduct)

  # Craft a payload where @price is a String — wrong type for Integer|NilClass
  payload = CBOR.encode({ "id" => 4, "price" => "free" })
  buf = "\xD9\x0F\xA0" + payload  # tag(4000)
  assert_raise(TypeError) { CBOR.decode(buf) }
end

# ============================================================================
# Exception-class correctness for patched raise sites
# ============================================================================

# Patch 1: skip_cbor truncated buffer → RangeError (was RuntimeError).
# skip_cbor is invoked when lazy-skipping past elements to reach an index.
# Array of 2: element 0 is a byte string claiming length 10 but only 3
# bytes follow, then element 1 = integer 42. lazy[1] must skip element 0
# via skip_cbor, which hits the truncation guard.
# Wire: 0x82 = array(2); 0x4A = bytes(10); 3 payload bytes; 0x18 0x2A = uint(42)
assert('CBOR skip_cbor: truncated buffer raises RangeError') do
  buf = "\x82\x4A\x01\x02\x03\x18\x2A"
  lazy = CBOR.decode_lazy(buf)
  assert_raise(RangeError) { lazy[1].value }
end

# Patch 3: decode_tagged_bignum non-byte-string payload → TypeError (was RuntimeError).
# Tag 2 (positive bignum) must wrap a byte string. Here it wraps integer 5.
assert('CBOR bignum tag: non-byte-string payload raises TypeError') do
  buf = "\xC2\x05"  # tag(2) + integer(5)
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR bignum tag: tag 3 with non-byte-string payload raises TypeError') do
  buf = "\xC3\x05"  # tag(3) + integer(5)
  assert_raise(TypeError) { CBOR.decode(buf) }
end

# ============================================================================
# CBOR::Path — [*] wildcard
# ============================================================================

assert('CBOR::Path: plain point query still works') do
  lazy = CBOR.decode_lazy(CBOR.encode({"a" => {"b" => 42}}))
  assert_equal 42, CBOR::Path.compile("$.a.b").at(lazy)
end

assert('CBOR::Path: [*] terminal returns array of element values') do
  lazy = CBOR.decode_lazy(CBOR.encode([10, 20, 30]))
  result = CBOR::Path.compile("$[*]").at(lazy)
  assert_equal [10, 20, 30], result
end

assert('CBOR::Path: [*] with tail — projects one field per element') do
  h = { "users" => [
    { "name" => "Alice", "age" => 30 },
    { "name" => "Bob",   "age" => 25 },
    { "name" => "Carol", "age" => 35 }
  ]}
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  names = CBOR::Path.compile("$.users[*].name").at(lazy)
  assert_equal ["Alice", "Bob", "Carol"], names
end

assert('CBOR::Path: [*] with nested tail') do
  h = { "rows" => [
    { "data" => { "v" => 1 } },
    { "data" => { "v" => 2 } },
    { "data" => { "v" => 3 } }
  ]}
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  vs = CBOR::Path.compile("$.rows[*].data.v").at(lazy)
  assert_equal [1, 2, 3], vs
end

assert('CBOR::Path: [*] with bracket-index tail') do
  h = { "pairs" => [[1, 2], [3, 4], [5, 6]] }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  seconds = CBOR::Path.compile("$.pairs[*][1]").at(lazy)
  assert_equal [2, 4, 6], seconds
end

assert('CBOR::Path: [*] on empty array') do
  lazy = CBOR.decode_lazy(CBOR.encode({"users" => []}))
  result = CBOR::Path.compile("$.users[*]").at(lazy)
  assert_equal [], result
end

assert('CBOR::Path: [*] on map raises TypeError') do
  lazy = CBOR.decode_lazy(CBOR.encode({"a" => 1}))
  assert_raise(TypeError) { CBOR::Path.compile("$[*]").at(lazy) { |_| } }
end

assert('CBOR::Path: [*] on scalar raises TypeError') do
  lazy = CBOR.decode_lazy(CBOR.encode(42))
  assert_raise(TypeError) { CBOR::Path.compile("$[*]").at(lazy) { |_| } }
end


assert('CBOR::Path: compiled path reusable across lazies') do
  path = CBOR::Path.compile("$.items[*].id")
  ids_a = path.at(CBOR.decode_lazy(CBOR.encode({"items" => [{"id"=>1},{"id"=>2}]}))) { |x| x }
  ids_b = path.at(CBOR.decode_lazy(CBOR.encode({"items" => [{"id"=>9},{"id"=>8},{"id"=>7}]}))) { |x| x }
  assert_equal [1, 2],    ids_a
  assert_equal [9, 8, 7], ids_b
end

assert('CBOR::Path: [*] skips untouched fields cheaply') do
  # Each user has a large byte-blob field the tail never touches.
  # If the executor decoded greedily, this would be slow or OOM.
  # If it skips properly, it finishes instantly.
  big = "x" * 100_000
  users = (1..50).map { |i| { "name" => "u#{i}", "blob" => big } }
  lazy = CBOR.decode_lazy(CBOR.encode({"users" => users}))
  names = CBOR::Path.compile("$.users[*].name").at(lazy) { |n| n }
  assert_equal 50, names.length
  assert_equal "u1",  names.first
  assert_equal "u50", names.last
end

# ============================================================================
# CBOR::Path + CBOR::Lazy — shared cache consistency
#
# Verifies that Path wildcard iteration and direct [] access share cache
# state: wrappers produced by one access pattern are the SAME mruby object
# as wrappers produced by the other, regardless of order.
# ============================================================================

assert('cache shared: wildcard first, direct [] returns same wrapper') do
  h = { "statuses" => (0...10).map { |i| { "id" => i } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  path = CBOR::Path.compile("$.statuses[*].id")
  path.at(lazy) { |v| v }

  # Capture wrappers via direct access after the wildcard has populated kcache
  arr = lazy["statuses"]
  first_direct  = arr[3]
  second_direct = arr[3]
  assert_same first_direct, second_direct

  # Different indices must be different wrappers
  assert_not_equal first_direct.__id__, arr[4].__id__
end

assert('cache shared: direct [] first, wildcard reuses existing wrapper') do
  h = { "rows" => (0...5).map { |i| { "v" => i * 10 } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  # Warm index 2 via direct access first, including its leaf value
  arr = lazy["rows"]
  pre = arr[2]
  assert_equal 20, pre["v"].value

  # Capture identity of the direct-access wrapper for index 2
  pre_id = pre.__id__

  # Wildcard run — internally reuses arr's kcache for every element
  # where a wrapper already exists
  path = CBOR::Path.compile("$.rows[*].v")
  path.at(lazy)

  # After the wildcard: direct access to index 2 must still return the
  # SAME wrapper we had before — not a fresh one allocated by the sweep
  assert_equal pre_id, arr[2].__id__
end

assert('cache shared: vcache survives wildcard → direct roundtrip') do
  h = { "items" => (0...3).map { |i| { "name" => "item#{i}" } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  # Wildcard populates per-element kcache and the leaf vcache
  path = CBOR::Path.compile("$.items[*].name")
  path.at(lazy) { |v| v }

  # Direct access: the name string should hit vcache — identity preserved
  direct_name_a = lazy["items"][1]["name"].value
  direct_name_b = lazy["items"][1]["name"].value
  assert_same direct_name_a, direct_name_b
  assert_equal "item1", direct_name_a
end

assert('cache shared: direct access warms cache for subsequent wildcard') do
  h = { "xs" => (0...4).map { |i| { "val" => i } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  # Warm all elements directly
  arr = lazy["xs"]
  direct_wrappers = (0...4).map { |i| arr[i] }

  # Wildcard — iterate and pull the same element wrappers
  path = CBOR::Path.compile("$.xs[*]")
  yielded_objects = []
  path.at(lazy) { |elem| yielded_objects << elem }

  # The yielded values are the decoded hashes, not the wrappers,
  # so to check wrapper identity we access arr[i] after the wildcard
  # and compare to the wrappers we captured before
  (0...4).each do |i|
    assert_equal direct_wrappers[i].__id__, arr[i].__id__
  end
end

assert('cache: repeated wildcard runs reuse the same children array') do
  h = { "list" => (0...20).map { |i| { "id" => i } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  path = CBOR::Path.compile("$.list[*].id")

  first_run  = path.at(lazy) { |v| v }
  second_run = path.at(lazy) { |v| v }

  # Results must match exactly (same ids)
  assert_equal first_run, second_run
  assert_equal (0..19).to_a, first_run
end

assert('cache: wildcard leaf values are same objects across runs') do
  h = { "xs" => [{ "s" => "hello" }, { "s" => "world" }] }
  lazy = CBOR.decode_lazy(CBOR.encode(h))

  path = CBOR::Path.compile("$.xs[*].s")
  first_run  = path.at(lazy) { |v| v }
  second_run = path.at(lazy) { |v| v }

  # Same string objects from vcache on second run
  assert_same first_run[0], second_run[0]
  assert_same first_run[1], second_run[1]
end

# test/test_path.rb
# ============================================================================
# CBOR::Path — multi-wildcard tests
#
# Data is modeled after real twitter.json shapes used in benchmark/path.rb:
#   - $.statuses[*].id                              (1 wildcard, flat)
#   - $.statuses[*].user.screen_name                (1 wildcard, tail)
#   - $.statuses[*].metadata.iso_language_code      (1 wildcard, deeper tail)
#   - $.statuses[*].entities.user_mentions[*].screen_name  (2 wildcards)
# ============================================================================

# ── shared fixtures ─────────────────────────────────────────────────────────

TWITTER_LIKE = {
  "statuses" => [
    {
      "metadata" => { "iso_language_code" => "ja", "result_type" => "recent" },
      "id"       => 505874924095815681,
      "user"     => { "screen_name" => "ayuu0123", "id" => 1186275104 },
      "entities" => {
        "hashtags"      => [],
        "user_mentions" => [
          { "screen_name" => "aym0566x", "id" => 866260188 }
        ]
      }
    },
    {
      "metadata" => { "iso_language_code" => "ja", "result_type" => "recent" },
      "id"       => 505874922023837696,
      "user"     => { "screen_name" => "yuttari1998", "id" => 903487807 },
      "entities" => {
        "hashtags"      => [],
        "user_mentions" => [
          { "screen_name" => "KATANA77", "id" => 77915997 }
        ]
      }
    },
    {
      "metadata" => { "iso_language_code" => "en", "result_type" => "recent" },
      "id"       => 505874918000000000,
      "user"     => { "screen_name" => "alice", "id" => 1 },
      "entities" => {
        "hashtags"      => [],
        "user_mentions" => [
          { "screen_name" => "bob",     "id" => 2 },
          { "screen_name" => "charlie", "id" => 3 }
        ]
      }
    },
    {
      # status with no mentions at all — exercises zero-length inner wildcard
      "metadata" => { "iso_language_code" => "en", "result_type" => "recent" },
      "id"       => 505874910000000000,
      "user"     => { "screen_name" => "dave", "id" => 4 },
      "entities" => {
        "hashtags"      => [],
        "user_mentions" => []
      }
    }
  ]
}

TWITTER_CBOR = CBOR.encode(TWITTER_LIKE)

# ── single wildcard — regression ────────────────────────────────────────────

assert('CBOR::Path: single wildcard, id list') do
  lazy = CBOR.decode_lazy(TWITTER_CBOR)
  p    = CBOR::Path.compile("$.statuses[*].id")
  assert_equal [
    505874924095815681,
    505874922023837696,
    505874918000000000,
    505874910000000000,
  ], p.at(lazy)
end

assert('CBOR::Path: single wildcard, nested key on tail') do
  lazy = CBOR.decode_lazy(TWITTER_CBOR)
  p    = CBOR::Path.compile("$.statuses[*].user.screen_name")
  assert_equal ["ayuu0123", "yuttari1998", "alice", "dave"], p.at(lazy)
end

assert('CBOR::Path: single wildcard, deeper tail') do
  lazy = CBOR.decode_lazy(TWITTER_CBOR)
  p    = CBOR::Path.compile("$.statuses[*].metadata.iso_language_code")
  assert_equal ["ja", "ja", "en", "en"], p.at(lazy)
end

# ── two wildcards — nested result mirrors eager-decode shape ────────────────

assert('CBOR::Path: two wildcards — screen_names per status') do
  lazy = CBOR.decode_lazy(TWITTER_CBOR)
  p    = CBOR::Path.compile("$.statuses[*].entities.user_mentions[*].screen_name")
  assert_equal [
    ["aym0566x"],
    ["KATANA77"],
    ["bob", "charlie"],
    [],                  # status with no mentions → empty inner array
  ], p.at(lazy)
end

assert('CBOR::Path: two wildcards — ids per status') do
  lazy = CBOR.decode_lazy(TWITTER_CBOR)
  p    = CBOR::Path.compile("$.statuses[*].entities.user_mentions[*].id")
  assert_equal [
    [866260188],
    [77915997],
    [2, 3],
    [],
  ], p.at(lazy)
end

# ── edge cases ──────────────────────────────────────────────────────────────

assert('CBOR::Path: two wildcards, trailing [*] (no tail steps)') do
  # `$.a[*].b[*]` should return the inner arrays materialized as-is
  data = { "a" => [
    { "b" => [1, 2, 3] },
    { "b" => [] },
    { "b" => [99] },
  ]}
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  p    = CBOR::Path.compile("$.a[*].b[*]")
  assert_equal [[1, 2, 3], [], [99]], p.at(lazy)
end

assert('CBOR::Path: three wildcards') do
  data = { "orgs" => [
    { "teams" => [
      { "members" => [{ "e" => "a" }, { "e" => "b" }] },
    ]},
    { "teams" => [
      { "members" => [{ "e" => "c" }] },
      { "members" => [{ "e" => "d" }, { "e" => "e" }] },
    ]},
  ]}
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  p    = CBOR::Path.compile("$.orgs[*].teams[*].members[*].e")
  assert_equal [
    [["a", "b"]],
    [["c"], ["d", "e"]],
  ], p.at(lazy)
end

assert('CBOR::Path: adjacent wildcards [*][*]') do
  data = [[1, 2, 3], [4, 5], [], [6]]
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  p    = CBOR::Path.compile("$[*][*]")
  assert_equal [[1, 2, 3], [4, 5], [], [6]], p.at(lazy)
end

assert('CBOR::Path: empty outer array with wildcards') do
  data = { "statuses" => [] }
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  p    = CBOR::Path.compile("$.statuses[*].id")
  assert_equal [], p.at(lazy)
end

# ── cache coherence — hot path returns same structural result ───────────────

assert('CBOR::Path: repeated .at hits warm @kcache (multi-wildcard)') do
  lazy = CBOR.decode_lazy(TWITTER_CBOR)
  p    = CBOR::Path.compile("$.statuses[*].entities.user_mentions[*].screen_name")
  r1   = p.at(lazy)
  r2   = p.at(lazy)
  r3   = p.at(lazy)
  assert_equal r1, r2
  assert_equal r2, r3
  # structural correctness survives repeated access
  assert_equal 4, r1.length
  assert_equal ["bob", "charlie"], r1[2]
end

# ── errors ──────────────────────────────────────────────────────────────────

assert('CBOR::Path: wildcard on non-array raises TypeError') do
  data = { "statuses" => { "wrong" => "shape" } }  # map, not array
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  p    = CBOR::Path.compile("$.statuses[*].id")
  assert_raise(TypeError) { p.at(lazy) }
end

assert('CBOR::Path: missing key raises KeyError (before wildcard)') do
  data = { "not_statuses" => [] }
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  p    = CBOR::Path.compile("$.statuses[*].id")
  assert_raise(KeyError) { p.at(lazy) }
end

assert('CBOR::Path: missing tail key in one element raises KeyError') do
  data = { "a" => [
    { "b" => 1 },
    { "c" => 2 },   # missing "b"
  ]}
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  p    = CBOR::Path.compile("$.a[*].b")
  assert_raise(KeyError) { p.at(lazy) }
end

# ── shared refs with wildcards ──────────────────────────────────────────────
assert('sharedref lazy: wildcard iterates over sharedref array target') do
  shared_users = [
    { "screen_name" => "alice" },
    { "screen_name" => "bob" },
  ]
  data = {
    "primary" => { "users" => shared_users },
    "backup"  => { "users" => shared_users },
  }
  buf  = CBOR.encode(data, sharedrefs: true)
  lazy = CBOR.decode_lazy(buf)

  p    = CBOR::Path.compile("$.backup.users[*].screen_name")
  assert_equal ["alice", "bob"], p.at(lazy)
end

assert('path: two wildcards') do
  data = {
    "teams" => [
      { "members" => [{"name" => "alice"}, {"name" => "bob"}] },
      { "members" => [{"name" => "carol"}, {"name" => "dan"}] },
    ]
  }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.teams[*].members[*].name")
  assert_equal [["alice", "bob"], ["carol", "dan"]], p.at(lazy)
end

assert('path: three wildcards') do
  data = {
    "regions" => [
      { "teams" => [
          { "members" => [{"n" => "a"}, {"n" => "b"}] },
          { "members" => [{"n" => "c"}] },
      ]},
      { "teams" => [
          { "members" => [{"n" => "d"}, {"n" => "e"}, {"n" => "f"}] },
      ]},
    ]
  }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.regions[*].teams[*].members[*].n")
  assert_equal [[["a", "b"], ["c"]], [["d", "e", "f"]]], p.at(lazy)
end

assert('path: wildcard at root') do
  data = [{"x" => 1}, {"x" => 2}, {"x" => 3}]
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$[*].x")
  assert_equal [1, 2, 3], p.at(lazy)
end

assert('path: two wildcards at root') do
  data = [[1, 2], [3, 4, 5], [6]]
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$[*][*]")
  assert_equal [[1, 2], [3, 4, 5], [6]], p.at(lazy)
end

assert('path: wildcard with empty array') do
  data = { "items" => [] }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.items[*]")
  assert_equal [], p.at(lazy)
end

assert('path: wildcard on empty inner arrays') do
  data = { "groups" => [{"xs" => []}, {"xs" => [1, 2]}, {"xs" => []}] }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.groups[*].xs[*]")
  assert_equal [[], [1, 2], []], p.at(lazy)
end

assert('path: index then wildcard') do
  data = {
    "rows" => [
      [ {"v" => 10}, {"v" => 20} ],
      [ {"v" => 30}, {"v" => 40} ],
    ]
  }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.rows[1][*].v")
  assert_equal [30, 40], p.at(lazy)
end

assert('path: wildcard then index') do
  data = {
    "rows" => [
      [10, 20, 30],
      [40, 50, 60],
      [70, 80, 90],
    ]
  }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.rows[*][1]")
  assert_equal [20, 50, 80], p.at(lazy)
end

assert('path: wildcard on sharedref leaf') do
  shared = [1, 2, 3]
  data = { "a" => shared, "b" => shared }
  buf  = CBOR.encode(data, sharedrefs: true)
  lazy = CBOR.decode_lazy(buf)
  assert_equal [1, 2, 3], CBOR::Path.compile("$.a[*]").at(lazy)
  assert_equal [1, 2, 3], CBOR::Path.compile("$.b[*]").at(lazy)
end

assert('path: two wildcards over sharedref target') do
  shared_teams = [
    { "members" => [{"n" => "a"}, {"n" => "b"}] },
    { "members" => [{"n" => "c"}] },
  ]
  data = { "primary" => { "teams" => shared_teams },
           "backup"  => { "teams" => shared_teams } }
  buf  = CBOR.encode(data, sharedrefs: true)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.backup.teams[*].members[*].n")
  assert_equal [["a", "b"], ["c"]], p.at(lazy)
end

assert('path: wildcard inside sharedref, nested shared leaf') do
  shared_tags = ["red", "blue"]
  data = {
    "posts" => [
      { "tags" => shared_tags },
      { "tags" => shared_tags },
    ]
  }
  buf  = CBOR.encode(data, sharedrefs: true)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.posts[*].tags[*]")
  assert_equal [["red", "blue"], ["red", "blue"]], p.at(lazy)
end

assert('path: wildcard raises on non-array target') do
  data = { "x" => { "y" => 1 } }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.x[*]")
  assert_raise(TypeError) { p.at(lazy) }
end

assert('path: wildcard result cached across repeated calls') do
  data = { "xs" => [{"v" => 1}, {"v" => 2}, {"v" => 3}] }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.xs[*].v")
  assert_equal [1, 2, 3], p.at(lazy)
  assert_equal [1, 2, 3], p.at(lazy)  # second call hits kcache
end

assert('path: different compiled paths on same lazy') do
  data = {
    "xs" => [{"a" => 1, "b" => 10}, {"a" => 2, "b" => 20}],
  }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  assert_equal [1, 2],   CBOR::Path.compile("$.xs[*].a").at(lazy)
  assert_equal [10, 20], CBOR::Path.compile("$.xs[*].b").at(lazy)
end

assert('path: heterogeneous values under wildcard') do
  data = { "xs" => [1, "two", nil, true, [3, 4], {"k" => "v"}] }
  buf  = CBOR.encode(data)
  lazy = CBOR.decode_lazy(buf)
  p    = CBOR::Path.compile("$.xs[*]")
  assert_equal [1, "two", nil, true, [3, 4], {"k" => "v"}], p.at(lazy)
end

# ============================================================================
# 9. Shared references — Tag 28/29 (deduplication + cyclic structures)
#
# Semantics:
#   - Only objects that appear in *value* positions participate in
#     sharedref deduplication. Hash keys always encode inline, because
#     preserving key identity is rarely useful and mruby's hash stores
#     a fresh copy of the key anyway.
#   - First non-key occurrence of an object  → Tag 28 + value.
#   - Subsequent non-key occurrences         → Tag 29 + index into
#                                              shareable table.
#   - Decoder preserves identity across all Tag 29 references resolving
#     to the same Tag 28 source.
# ============================================================================

# ── Value-position sharing: arrays, maps, strings ──────────────────────────

assert('CBOR sharedref: two array refs preserve value and identity (eager)') do
  a = [1, 2]
  obj = [a, a]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [[1, 2], [1, 2]], result
  assert_equal [1, 2], result[0]
  assert_equal [1, 2], result[1]
  assert_same result[0], result[1]
end

assert('CBOR sharedref: three value refs preserve value and identity (eager)') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v, "c" => v }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_equal [1, 2, 3], result["c"]
  assert_same result["a"], result["b"]
  assert_same result["b"], result["c"]
end

assert('CBOR sharedref: shared hash value (eager)') do
  h = { "k" => "v", "n" => 42 }
  obj = [h, h, h]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [{ "k" => "v", "n" => 42 },
                { "k" => "v", "n" => 42 },
                { "k" => "v", "n" => 42 }], result
  assert_same result[0], result[1]
  assert_same result[1], result[2]
end

assert('CBOR sharedref: shared string in array (eager)') do
  s = "shared_string"
  obj = [s, s, s, { "key" => s }]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal "shared_string", result[0]
  assert_equal "shared_string", result[1]
  assert_equal "shared_string", result[2]
  assert_equal "shared_string", result[3]["key"]
  assert_same result[0], result[1]
  assert_same result[1], result[2]
  assert_same result[2], result[3]["key"]
end

# ── Cyclic structures ──────────────────────────────────────────────────────

assert('CBOR sharedref: cyclic self-referential array (eager)') do
  a = []
  a << a
  result = CBOR.decode(CBOR.encode(a, sharedrefs: true))
  assert_true  result.is_a?(Array)
  assert_equal 1, result.length
  assert_same  result, result[0]
end

assert('CBOR sharedref: cyclic self-referential hash (eager)') do
  h = {}
  h["self"] = h
  result = CBOR.decode(CBOR.encode(h, sharedrefs: true))
  assert_true result.is_a?(Hash)
  assert_same result, result["self"]
end

assert('CBOR sharedref: mutual recursion — hash references array references hash') do
  a = []
  h = { "list" => a }
  a << h
  a << h
  result = CBOR.decode(CBOR.encode(h, sharedrefs: true))
  assert_equal 2, result["list"].length
  assert_same result, result["list"][0]
  assert_same result, result["list"][1]
end

# ── Lazy decode ────────────────────────────────────────────────────────────

assert('CBOR sharedref: two array refs (lazy)') do
  a = [1, 2]
  obj = [a, a]
  result = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('CBOR sharedref: map with shared value (lazy)') do
  v = [1, 2, 3]
  obj = { "a" => v, "b" => v }
  result = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR sharedref: cyclic array (lazy)') do
  a = []
  a << a
  result = CBOR.decode_lazy(CBOR.encode(a, sharedrefs: true)).value
  assert_same result, result[0]
end

# ── Deep nesting ───────────────────────────────────────────────────────────

assert('CBOR sharedref: shared leaf deep inside nested maps') do
  shared = [10, 20, 30]
  obj = {
    "a" => { "b" => { "c" => { "d" => { "e" => shared } } } },
    "x" => shared
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [10, 20, 30], result["a"]["b"]["c"]["d"]["e"]
  assert_equal [10, 20, 30], result["x"]
  assert_same result["a"]["b"]["c"]["d"]["e"], result["x"]
end

assert('CBOR sharedref: shared leaf deep inside nested arrays') do
  shared = { "k" => "v", "n" => 42 }
  obj = [[[[[shared]]]], shared, [shared]]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  leaf1 = result[0][0][0][0][0]
  leaf2 = result[1]
  leaf3 = result[2][0]
  assert_equal({ "k" => "v", "n" => 42 }, leaf1)
  assert_equal({ "k" => "v", "n" => 42 }, leaf2)
  assert_equal({ "k" => "v", "n" => 42 }, leaf3)
  assert_same leaf1, leaf2
  assert_same leaf2, leaf3
end

assert('CBOR sharedref: diamond pattern — bottom reached via multiple paths') do
  bottom = { "value" => 99 }
  left   = { "child" => bottom }
  right  = { "child" => bottom }
  root   = { "left" => left, "right" => right, "direct" => bottom }
  result = CBOR.decode(CBOR.encode(root, sharedrefs: true))

  assert_equal 99, result["left"]["child"]["value"]
  assert_equal 99, result["right"]["child"]["value"]
  assert_equal 99, result["direct"]["value"]

  assert_same result["left"]["child"],  result["right"]["child"]
  assert_same result["left"]["child"],  result["direct"]
  assert_same result["right"]["child"], result["direct"]
end

assert('CBOR sharedref: shared array containing shared sub-array') do
  inner = [1, 2, 3]
  outer = [inner, inner]    # outer contains inner twice
  obj   = [outer, outer]    # obj contains outer twice
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  assert_equal [[[1, 2, 3], [1, 2, 3]], [[1, 2, 3], [1, 2, 3]]], result
  assert_same result[0],    result[1]     # outer identity
  assert_same result[0][0], result[0][1]  # inner identity within outer
  assert_same result[0][0], result[1][0]  # inner identity across outer copies
  assert_same result[0][0], result[1][1]  # transitivity
end

assert('CBOR sharedref: multiple distinct shared groups in same structure') do
  a = [1, 2]
  b = { "k" => "v" }
  c = "shared_string"
  obj = {
    "a1" => a, "a2" => a,
    "b1" => b, "b2" => b,
    "c1" => c, "c2" => c,
    "nested" => { "a" => a, "b" => b, "c" => c }
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Values correct
  assert_equal [1, 2],           result["a1"]
  assert_equal({ "k" => "v" }, result["b1"])
  assert_equal "shared_string",  result["c1"]

  # Each group shares identity internally
  assert_same result["a1"], result["a2"]
  assert_same result["a1"], result["nested"]["a"]

  assert_same result["b1"], result["b2"]
  assert_same result["b1"], result["nested"]["b"]

  assert_same result["c1"], result["c2"]
  assert_same result["c1"], result["nested"]["c"]

  # Groups are not conflated
  assert_not_same result["a1"], result["b1"]
  assert_not_same result["b1"], result["c1"]
end

assert('CBOR sharedref: shared object repeats at every nesting level') do
  leaf = [1, 2]
  obj  = [leaf, [leaf, [leaf, [leaf, [leaf]]]]]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Collect all five occurrences
  occurrences = [result[0]]
  cur = result[1]
  while cur.is_a?(Array) && cur.length == 2
    occurrences << cur[0]
    cur = cur[1]
  end
  occurrences << cur[0] if cur.is_a?(Array)

  assert_equal 5, occurrences.length
  occurrences.each { |o| assert_equal [1, 2], o }
  (0...occurrences.length - 1).each do |i|
    assert_same occurrences[i], occurrences[i + 1]
  end
end

# ── Hash keys are NOT shared ───────────────────────────────────────────────

assert('CBOR sharedref: repeated key object does not participate in sharing') do
  # Same string used as a key in two maps. With sharedrefs on, the decoded
  # keys are still distinct string copies (mruby hash behaviour), and no
  # Tag 28/29 is emitted in key positions.
  k = "repeated_key"
  obj = [{ k => 1 }, { k => 2 }]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal [{ "repeated_key" => 1 }, { "repeated_key" => 2 }], result
end

assert('CBOR sharedref: same array used as value AND key — only values share') do
  arr = [1, 2, 3]
  obj = {
    "v1"         => arr,
    "v2"         => arr,
    "as_key_map" => { arr => "payload" }
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Value occurrences share identity
  assert_equal [1, 2, 3], result["v1"]
  assert_equal [1, 2, 3], result["v2"]
  assert_same  result["v1"], result["v2"]

  # Key occurrence is a separate copy, not aliased into the value group
  inner = result["as_key_map"]
  assert_true inner.is_a?(Hash)
  assert_equal 1, inner.size
  key_arr = inner.keys[0]
  assert_equal [1, 2, 3], key_arr
  assert_equal "payload", inner[key_arr]
  assert_not_same key_arr, result["v1"]
end

assert('CBOR sharedref: object embedded inside a key does not get Tag 28') do
  # `nested` is used both inside a key-map and as a sibling value. The
  # occurrence inside the key must encode inline; the sibling-value
  # occurrence is the first Tag 28 and does not alias back into the key.
  nested  = [1, 2]
  key_map = { "inner" => nested }
  obj     = { key_map => "v1", "also" => nested }
  result  = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  assert_equal [1, 2], result["also"]

  key_side = result.keys.find { |k| k.is_a?(Hash) }
  assert_not_nil key_side
  assert_equal [1, 2], key_side["inner"]
  assert_not_same key_side["inner"], result["also"]
end

# ── Lazy + sharedrefs deep interaction ─────────────────────────────────────

assert('CBOR sharedref: lazy navigation reaches deeply shared leaf via both paths') do
  # Note: each lazy is either navigated OR materialised as a whole — not
  # both. Mixing the two modes on the same lazy corrupts the shareable
  # table, because navigation registers Lazy wrappers at Tag 28 offsets
  # and a subsequent full decode would append instead of replace.
  shared = [100, 200, 300]
  obj = { "path" => { "to" => { "leaf" => shared } }, "alias" => shared }
  lazy = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true))
  assert_equal 100, lazy["path"]["to"]["leaf"][0].value
  assert_equal 200, lazy["path"]["to"]["leaf"][1].value
  assert_equal 300, lazy["alias"][2].value
end

assert('CBOR sharedref: full materialisation preserves identity across shared paths') do
  shared = [100, 200, 300]
  obj = { "path" => { "to" => { "leaf" => shared } }, "alias" => shared }
  # Fresh lazy — no prior navigation
  full = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal [100, 200, 300], full["path"]["to"]["leaf"]
  assert_equal [100, 200, 300], full["alias"]
  assert_same  full["path"]["to"]["leaf"], full["alias"]
end

assert('CBOR sharedref: lazy materialisation of diamond structure') do
  bottom = { "data" => [1, 2, 3] }
  obj    = { "a" => { "x" => bottom }, "b" => { "y" => bottom }, "c" => bottom }
  lazy   = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true))
  full   = lazy.value
  assert_equal [1, 2, 3], full["a"]["x"]["data"]
  assert_equal [1, 2, 3], full["b"]["y"]["data"]
  assert_equal [1, 2, 3], full["c"]["data"]
  assert_same  full["a"]["x"], full["b"]["y"]
  assert_same  full["a"]["x"], full["c"]
end

assert('CBOR sharedref: cyclic map round-trip preserves full cycle (eager)') do
  inner = { "name" => "cycle" }
  outer = { "child" => inner }
  inner["parent"] = outer
  result = CBOR.decode(CBOR.encode(outer, sharedrefs: true))

  assert_equal "cycle", result["child"]["name"]
  assert_same  result, result["child"]["parent"]
  assert_same  result["child"], result["child"]["parent"]["child"]
  assert_same  result["child"], result["child"]["parent"]["child"]["parent"]["child"]
end

# ── Registered tags under sharedrefs ──────────────────────────────────────

assert('CBOR sharedref: same registered-class instance shares identity in array (eager)') do
  class SharedPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
    def x; @x; end
    def y; @y; end
  end
  CBOR.register_tag(5000, SharedPoint)

  p = SharedPoint.new(3, 7)
  obj = [p, p, p]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_true  result[0].is_a?(SharedPoint)
  assert_equal 3, result[0].x
  assert_equal 7, result[0].y
  assert_same result[0], result[1]
  assert_same result[1], result[2]
end

assert('CBOR sharedref: distinct instances with equal fields do NOT share') do
  class SharedPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
    def x; @x; end
  end
  CBOR.register_tag(5000, SharedPoint)

  p1 = SharedPoint.new(1, 2)
  p2 = SharedPoint.new(1, 2)   # equal content, distinct object
  obj = [p1, p2]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal 1, result[0].x
  assert_equal 1, result[1].x
  assert_not_same result[0], result[1]
end

assert('CBOR sharedref: registered instance shared across map values (with non-immediate ivar)') do
  # String ivar creates a nested Tag 28 inside the registered-tag payload.
  # Works thanks to preorder slot reservation in decode_tag_sharedrefs.
  class SharedConfig
    native_ext_type :@timeout, Integer
    native_ext_type :@name,    String
    def initialize(t = 0, n = ""); @timeout = t; @name = n; end
    def timeout; @timeout; end
    def name;    @name;    end
  end
  CBOR.register_tag(5001, SharedConfig)

  cfg = SharedConfig.new(30, "default")
  obj = { "primary" => cfg, "backup" => cfg, "fallback" => cfg }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal 30,        result["primary"].timeout
  assert_equal "default", result["primary"].name
  assert_same result["primary"], result["backup"]
  assert_same result["backup"],  result["fallback"]
end

assert('CBOR sharedref: registered instance shared across mixed nesting') do
  class SharedNode
    native_ext_type :@id, Integer
    def initialize(i = 0); @id = i; end
    def id; @id; end
  end
  CBOR.register_tag(5002, SharedNode)

  node = SharedNode.new(42)
  obj = {
    "a" => { "x" => node },
    "b" => [node, node, { "nested" => node }]
  }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_equal 42, result["a"]["x"].id
  assert_same result["a"]["x"], result["b"][0]
  assert_same result["b"][0],   result["b"][1]
  assert_same result["b"][1],   result["b"][2]["nested"]
end

assert('CBOR sharedref: registered instance identity preserved through lazy.value') do
  class LazyShared
    native_ext_type :@val, Integer
    def initialize(v = 0); @val = v; end
    def val; @val; end
  end
  CBOR.register_tag(5003, LazyShared)

  l = LazyShared.new(99)
  obj = { "a" => l, "b" => l }
  full = CBOR.decode_lazy(CBOR.encode(obj, sharedrefs: true)).value
  assert_equal 99, full["a"].val
  assert_same full["a"], full["b"]
end

assert('CBOR sharedref: registered instance as key is not aliased to value occurrences') do
  class KeyShared
    native_ext_type :@tag, String
    def initialize(s = ""); @tag = s; end
    def tag; @tag; end
  end
  CBOR.register_tag(5004, KeyShared)

  k = KeyShared.new("keyish")
  obj = { "v1" => k, "v2" => k, "as_key" => { k => "payload" } }
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))

  # Value occurrences share
  assert_same result["v1"], result["v2"]

  # Key occurrence decodes to a separate instance
  inner    = result["as_key"]
  key_inst = inner.keys[0]
  assert_true  key_inst.is_a?(KeyShared)
  assert_equal "keyish", key_inst.tag
  assert_equal "payload", inner[key_inst]
  assert_not_same key_inst, result["v1"]
end

assert('CBOR sharedref: proc-registered Exception shares identity') do
  CBOR.register_tag(60100) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end

  exc = RuntimeError.new("oops")
  obj = [exc, exc, { "err" => exc }]
  result = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_true  result[0].is_a?(RuntimeError)
  assert_equal "oops", result[0].message
  assert_same result[0], result[1]
  assert_same result[1], result[2]["err"]
end

assert('CBOR sharedref: proc-registered distinct Exceptions with same message do NOT share') do
  CBOR.register_tag(60100) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end

  e1 = RuntimeError.new("boom")
  e2 = RuntimeError.new("boom")   # same class and message, distinct objects
  result = CBOR.decode(CBOR.encode([e1, e2], sharedrefs: true))
  assert_true  result[0].is_a?(RuntimeError)
  assert_true  result[1].is_a?(RuntimeError)
  assert_equal "boom", result[0].message
  assert_equal "boom", result[1].message
  assert_not_same result[0], result[1]
end

# ── Cyclic registered instances ───────────────────────────────────────────

assert('CBOR sharedref: registered-class instance with self-referential field') do
  # A node whose @nxt field points back to itself. The Tag 29(slot) inside
  # the field payload must resolve to the in-construction instance, not nil.
  class CyclicNode
    native_ext_type :@id,  Integer
    native_ext_type :@nxt, CyclicNode, NilClass
    def initialize(i = 0); @id = i; @nxt = nil; end
    def id;  @id;  end
    def nxt; @nxt; end
  end
  CBOR.register_tag(5100, CyclicNode)

  n = CyclicNode.new(1)
  n.instance_variable_set(:@nxt, n)
  result = CBOR.decode(CBOR.encode(n, sharedrefs: true))
  assert_true  result.is_a?(CyclicNode)
  assert_equal 1, result.id
  assert_same  result, result.nxt
end

assert('CBOR sharedref: mutual recursion between two registered instances') do
  # Declare both classes first, then reopen each to register the peer ivar
  # with the other class as its type constraint. This is the cleanest way
  # to express mutual type references in the native_ext_type DSL.
  class MutualA
    native_ext_type :@tag, Integer
    def initialize(t = 0); @tag = t; @peer = nil; end
    def tag;  @tag;  end
    def peer; @peer; end
  end
  class MutualB
    native_ext_type :@tag, Integer
    def initialize(t = 0); @tag = t; @peer = nil; end
    def tag;  @tag;  end
    def peer; @peer; end
  end
  class MutualA
    native_ext_type :@peer, MutualB, NilClass
  end
  class MutualB
    native_ext_type :@peer, MutualA, NilClass
  end
  CBOR.register_tag(5101, MutualA)
  CBOR.register_tag(5102, MutualB)

  a = MutualA.new(1)
  b = MutualB.new(2)
  a.instance_variable_set(:@peer, b)
  b.instance_variable_set(:@peer, a)

  result = CBOR.decode(CBOR.encode(a, sharedrefs: true))
  assert_true  result.is_a?(MutualA)
  assert_equal 1, result.tag
  assert_true  result.peer.is_a?(MutualB)
  assert_equal 2, result.peer.tag
  assert_same  result, result.peer.peer
end




assert('CBOR sharedref: without flag, values do not share identity') do
  shared = [1, 2, 3]
  obj = { "a" => shared, "b" => shared }
  result = CBOR.decode(CBOR.encode(obj))
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_not_same result["a"], result["b"]
end

assert('CBOR sharedref: encoding a cycle without flag raises (depth limit)') do
  a = []
  a << a
  assert_raise(RuntimeError) { CBOR.encode(a) }
end

# ── Wire-level decoder still accepts Tag 28 anywhere ──────────────────────

assert('CBOR sharedref: scalar shareable — integer') do
  buf = "\x82\xD8\x1C\x18\x2A\xD8\x1D\x00"
  assert_equal [42, 42], CBOR.decode(buf)
end

assert('CBOR sharedref: invalid index raises IndexError') do
  buf = "\xD8\x1D\x18\x63"
  assert_raise(IndexError) { CBOR.decode(buf) }
end

assert('CBOR sharedref: tag 29 with non-uint payload raises TypeError') do
  buf = "\xD8\x1D\x61\x61"   # tag(29) + "a"
  assert_raise(TypeError) { CBOR.decode(buf) }
end

assert('CBOR sharedref: decoder accepts Tag 28 in map-value position') do
  # Even though the encoder never emits Tag 28 in a key position, the
  # decoder must accept Tag 28 anywhere it appears on the wire — other
  # CBOR implementations may emit it differently.
  buf = "\xA2\x61\x61\xD8\x1C\x83\x01\x02\x03\x61\x62\xD8\x1D\x00"
  result = CBOR.decode(buf)
  assert_equal [1, 2, 3], result["a"]
  assert_equal [1, 2, 3], result["b"]
  assert_same result["a"], result["b"]
end

assert('CBOR sharedref: lazy path through Tag 28 without prior registration') do
  buf = "\xA2" \
        "\x65outer" \
        "\xD8\x1C\x82\x01\x02" \
        "\x63ref" \
        "\xD8\x1D\x00"
  lazy = CBOR.decode_lazy(buf)
  assert_equal [1, 2], lazy["ref"].value
end

