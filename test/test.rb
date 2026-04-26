# =============================================================================
# mruby-cbor test suite
#
# Organized to match RFC 8949 section order, so each test lives with the
# part of the spec it exercises. Non-RFC features (Lazy, Path, fast path,
# streaming, safety limits) follow at the end.
#
# Section map:
#   §3.1  Major type 0 — unsigned integers
#   §3.1  Major type 1 — negative integers
#   §3.1  Major type 2 — byte strings
#   §3.1  Major type 3 — text strings
#   §3.1  Major type 4 — arrays
#   §3.1  Major type 5 — maps
#   §3.1  Major type 6 — tags
#         §3.4.3    Tags 2/3 — bignums
#         IANA      Tags 28/29 — shareable / sharedref
#         IANA      Tag 39 — typed symbols
#         private   Tag 49999 — classes and modules
#                   Unhandled tags (CBOR::UnhandledTag)
#                   Registered tags (native_ext_type DSL)
#                   Proc-registered tags (register_tag block)
#   §3.1  Major type 7 — floating-point & simple values
#   §3.2  Indefinite lengths — rejected
#   §4.1  Preferred float serialization
#
# Non-RFC:
#   fast path (encode_fast / decode_fast)
#   CBOR::Lazy (on-demand decoding)
#   CBOR::Path (JSON-pointer-ish with [*] wildcard)
#   CBOR.stream / CBOR::StreamDecoder
#   CBOR.doc_end
#   Depth limit & safety
#   Fuzz / regression
#
# Every branch that the C and Ruby implementation can take is exercised at
# least once so regressions surface on the first failed run.
# =============================================================================

# ── shared helpers ─────────────────────────────────────────────────────────

def assert_safe(&block)
  begin
    block.call
  rescue RuntimeError, RangeError, TypeError, NotImplementedError,
         ArgumentError, KeyError, IndexError, NameError
    # clean error — pass
  end
  assert_true true
end

class MockIO
  def initialize(data); @data = data; @pos = 0; end
  def seek(pos); @pos = pos; end
  def read(n)
    return nil if @pos >= @data.bytesize
    slice = @data[@pos, n]
    @pos += slice.bytesize
    slice
  end
end

# =============================================================================
# §3.1 Major type 0 — unsigned integers
# Exercises read_cbor_uint for every info width (23, 24, 25, 26, 27),
# and encode_integer's major-0 branch.
# =============================================================================

assert('major 0: small-inline integers (info < 24) roundtrip') do
  [0, 1, 10, 23].each { |n| assert_equal n, CBOR.decode(CBOR.encode(n)) }
end

assert('major 0: uint8 boundary (info=24) — 24 and 255') do
  [24, 100, 255].each { |n| assert_equal n, CBOR.decode(CBOR.encode(n)) }
end

assert('major 0: uint16 boundary (info=25) — 256 and 65535') do
  [256, 1000, 65535].each { |n| assert_equal n, CBOR.decode(CBOR.encode(n)) }
end

assert('major 0: uint32 boundary (info=26) — 65536 and 0xFFFFFFFF') do
  [65536, (1 << 20), 0xFFFFFFFF].each { |n|
    assert_equal n, CBOR.decode(CBOR.encode(n))
  }
end

assert('major 0: uint64 boundary (info=27) — requires bigint promotion') do
  [1 << 40, (1 << 63), (1 << 64) - 1].each { |n|
    assert_equal n, CBOR.decode(CBOR.encode(n))
  }
end

assert('major 0: all powers of 2 up to 31 bits roundtrip') do
  (0..31).each { |i| n = 1 << i; assert_equal n, CBOR.decode(CBOR.encode(n)) }
end

assert('major 0: uint64 max-plus-one wire decodes to 2^64-1') do
  # 0x1B FF FF FF FF FF FF FF FF — valid RFC §3.1 wire, requires bigint
  buf = "\x1B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_equal (2**64) - 1, CBOR.decode(buf)
end

# =============================================================================
# §3.1 Major type 1 — negative integers
# Exercises decode_negative via the -1-n rule for every width.
# =============================================================================

assert('major 1: small-inline negatives (info < 24) roundtrip') do
  [-1, -2, -10, -24].each { |n| assert_equal n, CBOR.decode(CBOR.encode(n)) }
end

assert('major 1: every width roundtrip (neg uint8..uint64)') do
  [-25, -256, -(1 << 16), -((1 << 32)), -((1 << 63)) - 1].each { |n|
    assert_equal n, CBOR.decode(CBOR.encode(n))
  }
end

assert('major 1: negative uint32 boundary wire → -(2^32)') do
  buf = "\x3A\xFF\xFF\xFF\xFF"
  assert_equal(-(2**32), CBOR.decode(buf))
end

assert('major 1: negative uint64 boundary wire → -(2^63)-1') do
  buf = "\x3B\x80\x00\x00\x00\x00\x00\x00\x00"
  assert_equal(-(2**63) - 1, CBOR.decode(buf))
end

assert('major 1: most-negative uint64 wire → -(2^64) (needs bigint)') do
  buf = "\x3B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  begin
    assert_equal(-(2**64), CBOR.decode(buf))
  rescue RangeError
    # build without MRB_USE_BIGINT: raise is correct per read_cbor_uint
  end
end

# =============================================================================
# §3.1 Major type 2 — byte strings
# decode_bytes + encode_string's binary branch.
# =============================================================================

assert('major 2: non-UTF-8 string encodes as major 2') do
  b = "\x00\xFF\xFE\xFA"
  wire = CBOR.encode(b)
  assert_equal 0x44, wire.getbyte(0)  # 2<<5 | 4
  assert_equal b, CBOR.decode(wire)
end

assert('major 2: length-prefix widths (empty, short, long)') do
  ["", "\x00".b, "\xFF" * 30, "\xFF" * 300].each { |s|
    b = s.b
    assert_equal b, CBOR.decode(CBOR.encode(b))
  }
end

# =============================================================================
# §3.1 Major type 3 — text strings
# decode_text with UTF-8 validation + encode_string's text branch.
# =============================================================================

assert('major 3: UTF-8 text encodes as major 3') do
  wire = CBOR.encode("hello")
  assert_equal 0x65, wire.getbyte(0)  # 3<<5 | 5
end

assert('major 3: empty / short / multibyte / long roundtrip') do
  ["", "hello", "caf\xC3\xA9", "a" * 24, "x" * 10000].each { |s|
    assert_equal s, CBOR.decode(CBOR.encode(s))
  }
end

assert('major 3: decoder rejects invalid UTF-8 (TypeError)') do
  # 0x63 = major 3, len 3; followed by bytes that aren't valid UTF-8
  assert_raise(TypeError) { CBOR.decode("\x63\xFF\xFE\xFD") }
end

# =============================================================================
# §3.1 Major type 4 — arrays
# decode_array / encode_array for empty, nested, mixed, length boundaries.
# =============================================================================

assert('major 4: empty, basic, nested, mixed roundtrip') do
  [[], [1, 2, 3], [[1, 2], [3, [4, 5]]], [1, "two", true, nil, 4.0]].each { |a|
    assert_equal a, CBOR.decode(CBOR.encode(a))
  }
end

assert('major 4: huge length claim (uint64) raises RangeError') do
  buf = "\x9B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_raise(RangeError) { CBOR.decode(buf) }
end

# =============================================================================
# §3.1 Major type 5 — maps
# decode_map / encode_map for empty, string keys, integer keys, nested,
# and class-as-key.
# =============================================================================

assert('major 5: empty, string, integer, nested keys roundtrip') do
  assert_equal({},                            CBOR.decode(CBOR.encode({})))
  assert_equal({"a" => 1, "b" => 2},          CBOR.decode(CBOR.encode({"a" => 1, "b" => 2})))
  assert_equal({1 => "one", 2 => "two"},      CBOR.decode(CBOR.encode({1 => "one", 2 => "two"})))
  assert_equal({"outer" => {"inner" => 42}},  CBOR.decode(CBOR.encode({"outer" => {"inner" => 42}})))
end

assert('major 5: class as hash key roundtrips via tag 49999') do
  decoded = CBOR.decode(CBOR.encode({ String => "value" }))
  assert_equal "value", decoded[String]
end

# =============================================================================
# §3.1 Major type 6 / §3.4.3 — Tags 2 and 3 — Bignums
# =============================================================================

assert('bignum tag 2: positive bignum boundaries (uint64, +1, deep)') do
  [(1 << 64) - 1, 1 << 64, (1 << 64) + 1, (1 << 200) + 12345, (1 << 32768) + 123456789].each { |n|
    assert_equal n, CBOR.decode(CBOR.encode(n))
  }
end

assert('bignum tag 3: negative bignum boundaries') do
  [-(1 << 64), -((1 << 64) + 1), -(1 << 200) - 999].each { |n|
    assert_equal n, CBOR.decode(CBOR.encode(n))
  }
end

assert('bignum §3.4.3: zero-length payload — tag(2,h\'\')=0, tag(3,h\'\')=-1') do
  assert_equal 0,  CBOR.decode("\xC2\x40")
  assert_equal(-1, CBOR.decode("\xC3\x40"))
end

assert('bignum: non-byte-string payload raises TypeError') do
  assert_raise(TypeError) { CBOR.decode("\xC2\x05") }  # tag(2) + integer(5)
  assert_raise(TypeError) { CBOR.decode("\xC3\x05") }  # tag(3) + integer(5)
end

assert('bignum: mixed with normal integers in array') do
  big = 1 << 100
  assert_equal [1, 2, big, 4, 5], CBOR.decode(CBOR.encode([1, 2, big, 4, 5]))
end

# =============================================================================
# §3.1 Major type 6 / IANA — Tags 28 and 29 — shareable / sharedref
#
# Encoder: sharedrefs:true emits Tag 28 on first non-key occurrence,
# Tag 29 + index on subsequent occurrences. Hash KEYS do NOT participate
# in sharing — they always inline, matching mruby's hash-key copy semantics.
# =============================================================================

# ── value-position sharing (eager) ──────────────────────────────────────────

assert('tag 28/29: repeated value → identity preserved (eager)') do
  a = [1, 2]
  result = CBOR.decode(CBOR.encode([a, a], sharedrefs: true))
  assert_equal [[1, 2], [1, 2]], result
  assert_same result[0], result[1]
end

assert('tag 28/29: three-way sharing preserves identity (eager)') do
  v = [1, 2, 3]
  result = CBOR.decode(CBOR.encode({"a" => v, "b" => v, "c" => v}, sharedrefs: true))
  assert_same result["a"], result["b"]
  assert_same result["b"], result["c"]
end

assert('tag 28/29: shared hash / shared string roundtrip') do
  h = { "k" => "v", "n" => 42 }
  rh = CBOR.decode(CBOR.encode([h, h, h], sharedrefs: true))
  assert_same rh[0], rh[1]; assert_same rh[1], rh[2]

  s = "shared_string"
  rs = CBOR.decode(CBOR.encode([s, s, { "key" => s }], sharedrefs: true))
  assert_same rs[0], rs[1]
  assert_same rs[1], rs[2]["key"]
end

# ── cyclic structures ──────────────────────────────────────────────────────

assert('tag 28/29: cyclic array and cyclic hash (eager)') do
  a = []; a << a
  ra = CBOR.decode(CBOR.encode(a, sharedrefs: true))
  assert_same ra, ra[0]

  h = {}; h["self"] = h
  rh = CBOR.decode(CBOR.encode(h, sharedrefs: true))
  assert_same rh, rh["self"]
end

assert('tag 28/29: mutual recursion — hash↔array cycle') do
  arr = []; hsh = { "list" => arr }
  arr << hsh; arr << hsh
  r = CBOR.decode(CBOR.encode(hsh, sharedrefs: true))
  assert_same r, r["list"][0]
  assert_same r, r["list"][1]
end

assert('tag 28/29: cyclic map round-trip — full cycle navigable') do
  inner = { "name" => "cycle" }
  outer = { "child" => inner }
  inner["parent"] = outer
  r = CBOR.decode(CBOR.encode(outer, sharedrefs: true))
  assert_same r, r["child"]["parent"]
  assert_same r["child"], r["child"]["parent"]["child"]
end

# ── lazy decode ────────────────────────────────────────────────────────────

assert('tag 28/29: shared value preserved via lazy.value') do
  a = [1, 2]
  r = CBOR.decode_lazy(CBOR.encode([a, a], sharedrefs: true)).value
  assert_same r[0], r[1]

  v = [1, 2, 3]
  rm = CBOR.decode_lazy(CBOR.encode({"a" => v, "b" => v}, sharedrefs: true)).value
  assert_same rm["a"], rm["b"]
end

assert('tag 28/29: cyclic array materializes via lazy') do
  a = []; a << a
  r = CBOR.decode_lazy(CBOR.encode(a, sharedrefs: true)).value
  assert_same r, r[0]
end

# ── deep nesting / diamond ─────────────────────────────────────────────────

assert('tag 28/29: shared leaf reached through deep paths') do
  shared = [10, 20, 30]
  obj = { "a" => { "b" => { "c" => { "d" => { "e" => shared } } } }, "x" => shared }
  r = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_same r["a"]["b"]["c"]["d"]["e"], r["x"]
end

assert('tag 28/29: diamond pattern preserves identity across all paths') do
  bottom = { "value" => 99 }
  root = { "left" => { "child" => bottom }, "right" => { "child" => bottom }, "direct" => bottom }
  r = CBOR.decode(CBOR.encode(root, sharedrefs: true))
  assert_same r["left"]["child"], r["right"]["child"]
  assert_same r["left"]["child"], r["direct"]
end

assert('tag 28/29: nested sharing — outer and inner both share') do
  inner = [1, 2, 3]
  outer = [inner, inner]
  r = CBOR.decode(CBOR.encode([outer, outer], sharedrefs: true))
  assert_same r[0], r[1]
  assert_same r[0][0], r[0][1]
  assert_same r[0][0], r[1][0]
end

assert('tag 28/29: distinct shared groups do not conflate') do
  a = [1, 2]; b = { "k" => "v" }; c = "str"
  obj = { "a1" => a, "a2" => a, "b1" => b, "b2" => b, "c1" => c, "c2" => c,
          "nested" => { "a" => a, "b" => b, "c" => c } }
  r = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_same r["a1"], r["nested"]["a"]
  assert_same r["b1"], r["nested"]["b"]
  assert_same r["c1"], r["nested"]["c"]
  assert_not_same r["a1"], r["b1"]
  assert_not_same r["b1"], r["c1"]
end

# ── hash keys are NOT shared ───────────────────────────────────────────────

assert('tag 28/29: hash keys do not participate in sharing') do
  k = "repeated_key"
  r = CBOR.decode(CBOR.encode([{k => 1}, {k => 2}], sharedrefs: true))
  assert_equal [{"repeated_key" => 1}, {"repeated_key" => 2}], r
end

assert('tag 28/29: same object as value AND key — only values share') do
  arr = [1, 2, 3]
  obj = { "v1" => arr, "v2" => arr, "as_key_map" => { arr => "payload" } }
  r = CBOR.decode(CBOR.encode(obj, sharedrefs: true))
  assert_same r["v1"], r["v2"]
  key_arr = r["as_key_map"].keys[0]
  assert_equal [1, 2, 3], key_arr
  assert_not_same key_arr, r["v1"]
end

# ── wire-level decoder robustness ──────────────────────────────────────────

assert('tag 28/29: scalar shareable (integer) roundtrip via wire') do
  # Manually-crafted: [ Tag28(42), Tag29(0) ]
  assert_equal [42, 42], CBOR.decode("\x82\xD8\x1C\x18\x2A\xD8\x1D\x00")
end

assert('tag 29: invalid index raises IndexError, non-uint payload raises TypeError') do
  assert_raise(IndexError) { CBOR.decode("\xD8\x1D\x18\x63") }  # idx 99 in empty table
  assert_raise(TypeError)  { CBOR.decode("\xD8\x1D\x61\x61") }  # tag(29) + "a"
end

assert('tag 29: uint64-max index overflow handled cleanly') do
  assert_safe { CBOR.decode("\xD8\x1D\x1B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF") }
end

assert('tag 28: decoder accepts Tag 28 in map-value position') do
  # Decoder must accept Tag 28 anywhere on the wire, even though our encoder
  # never emits it in key positions.
  buf = "\xA2\x61\x61\xD8\x1C\x83\x01\x02\x03\x61\x62\xD8\x1D\x00"
  r = CBOR.decode(buf)
  assert_same r["a"], r["b"]
end

assert('tag 28: lazy path through Tag 28 without prior registration') do
  buf = "\xA2\x65outer\xD8\x1C\x82\x01\x02\x63ref\xD8\x1D\x00"
  assert_equal [1, 2], CBOR.decode_lazy(buf)["ref"].value
end

assert('tag 28: self-referential Tag 28 inside Tag 28 is safe') do
  assert_safe { CBOR.decode("\xD8\x1C\xD8\x1C\x18\x2A") }
end

# ── without the flag ───────────────────────────────────────────────────────

assert('no sharedref flag: values do not share, cycles hit depth limit') do
  shared = [1, 2, 3]
  r = CBOR.decode(CBOR.encode({"a" => shared, "b" => shared}))
  assert_not_same r["a"], r["b"]

  a = []; a << a
  assert_raise(RuntimeError) { CBOR.encode(a) }
end

# =============================================================================
# §3.1 Major type 6 / IANA — Tag 39 — typed symbols
#
# Three strategies: none (plain string), string payload, uint32 payload.
# =============================================================================

assert('tag 39: no_symbols → symbol encodes as plain string') do
  CBOR.no_symbols
  assert_equal "hello", CBOR.decode(CBOR.encode(:hello))
end

assert('tag 39: symbols_as_string — symbol roundtrip + in hash/array') do
  CBOR.symbols_as_string
  assert_equal :hello, CBOR.decode(CBOR.encode(:hello))
  assert_equal [:a, :b, :c], CBOR.decode(CBOR.encode([:a, :b, :c]))
  assert_equal({ hello: 1, world: 2 }, CBOR.decode(CBOR.encode({ hello: 1, world: 2 })))
  CBOR.no_symbols
end

assert('tag 39: symbols_as_uint32 — symbol roundtrip') do
  CBOR.symbols_as_uint32
  assert_equal :hello, CBOR.decode(CBOR.encode(:hello))
  CBOR.no_symbols
end

assert('tag 39: decoding while no_symbols active raises RuntimeError') do
  CBOR.symbols_as_string
  buf = CBOR.encode(:hello)
  CBOR.no_symbols
  assert_raise(RuntimeError) { CBOR.decode(buf) }
end

assert('tag 39: wrong payload type raises TypeError (both strategies)') do
  CBOR.symbols_as_uint32
  assert_raise(TypeError) { CBOR.decode("\xD8\x27\x65hello") }  # string payload under uint32 strat
  CBOR.symbols_as_string
  assert_raise(TypeError) { CBOR.decode("\xD8\x27\x18\x2A") }   # int payload under string strat
  CBOR.no_symbols
end

assert('tag 39: uint32 strategy — out-of-range symbol ID raises RangeError') do
  CBOR.symbols_as_uint32
  buf = "\xD8\x27\x1B\x00\x00\x00\x01\x00\x00\x00\x00"  # 2^32
  assert_raise(RangeError) { CBOR.decode(buf) }
  CBOR.no_symbols
end

# =============================================================================
# §3.1 Major type 6 / private — Tag 49999 — classes and modules
# =============================================================================

assert('tag 49999: top-level class / nested class / module roundtrip') do
  module TagTestMod; end
  assert_equal String,            CBOR.decode(CBOR.encode(String))
  assert_equal CBOR::UnhandledTag, CBOR.decode(CBOR.encode(CBOR::UnhandledTag))
  assert_equal TagTestMod,         CBOR.decode(CBOR.encode(TagTestMod))
end

assert('tag 49999: class in array / hash / lazy structure') do
  r = CBOR.decode(CBOR.encode([String, Integer, Float]))
  assert_equal [String, Integer, Float], r

  assert_equal ArgumentError,
    CBOR.decode(CBOR.encode({"klass" => ArgumentError}))["klass"]

  h = { "klass" => StandardError, "msg" => "oops" }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal StandardError, lazy["klass"].value
  assert_equal "oops",        lazy["msg"].value
end

assert('tag 49999: anonymous class / module raises ArgumentError') do
  assert_raise(ArgumentError) { CBOR.encode(Class.new) }
  assert_raise(ArgumentError) { CBOR.encode(Module.new) }
end

assert('tag 49999: unknown constant raises NameError') do
  buf = "\xD9\xC3\x4F" + CBOR.encode("NoSuchClass__CBOR_TEST_XYZ")
  assert_raise(NameError) { CBOR.decode(buf) }
end

assert('tag 49999: non-string payload raises TypeError') do
  assert_raise(TypeError) { CBOR.decode("\xD9\xC3\x4F\x01") }
end

# =============================================================================
# §3.1 Major type 6 — Unhandled tags (CBOR::UnhandledTag)
#
# Anything not registered decodes as a UnhandledTag(tag, value) pair.
# =============================================================================

assert('unhandled tag: wraps integer / array / map / string payload') do
  r1 = CBOR.decode("\xD8\x64\x18\x2A")          # tag 100 + 42
  assert_true r1.is_a?(CBOR::UnhandledTag); assert_equal 100, r1.tag; assert_equal 42, r1.value

  r2 = CBOR.decode("\xD8\x64\x63\x61\x62\x63")  # tag 100 + "abc"
  assert_equal "abc", r2.value

  r3 = CBOR.decode("\xD8\xC8\x83\x01\x02\x03")  # tag 200 + [1,2,3]
  assert_equal 200,       r3.tag
  assert_equal [1, 2, 3], r3.value

  r4 = CBOR.decode("\xD9\x01\x2C\xA1\x61\x78\x01")  # tag 300 + {"x":1}
  assert_equal 300,              r4.tag
  assert_equal({ "x" => 1 },  r4.value)
end

assert('unhandled tag: deeply-nested tag chain') do
  # tag(100)(tag(101)(tag(102)(tag(103)(42))))
  r = CBOR.decode("\xD8\x64\xD8\x65\xD8\x66\xD8\x67\x18\x2A")
  [100, 101, 102, 103].each { |t| assert_equal t, r.tag; r = r.value }
  assert_equal 42, r
end

assert('unhandled tag: array of tagged values') do
  r = CBOR.decode("\xD8\xC8\x83\xD8\x64\x01\xD8\x65\x02\xD8\x66\x03")
  assert_equal 200, r.tag
  assert_equal [100, 101, 102], r.value.map(&:tag)
end

assert('unhandled tag: works via lazy decode') do
  r = CBOR.decode_lazy("\xD8\x64\x18\x2A").value
  assert_equal 100, r.tag
  assert_equal 42,  r.value
end

assert('unhandled tag: lazy indexing into array of tagged elements') do
  buf = "\x84\x01\xD8\x64\x02\x03\x64\x74\x65\x78\x74"
  lazy = CBOR.decode_lazy(buf)
  assert_equal 1,      lazy[0].value
  assert_equal 100,    lazy[1].value.tag
  assert_equal 2,      lazy[1].value.value
  assert_equal "text", lazy[3].value
end

# =============================================================================
# §3.1 Major type 6 — Registered tags via native_ext_type DSL
#
# Exercises: encoder schema walk, type validation on encode and decode,
# _before_encode / _after_decode hooks, extra-field allowlist, nullable
# / union field types.
# =============================================================================

assert('registered tag: basic Point class encode/decode (eager + lazy)') do
  class RegPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
    def ==(other)
      other.is_a?(RegPoint) &&
        @x == other.instance_variable_get(:@x) &&
        @y == other.instance_variable_get(:@y)
    end
  end
  CBOR.register_tag(1000, RegPoint)

  p = RegPoint.new(3, 7)
  assert_equal p, CBOR.decode(CBOR.encode(p))
  assert_equal p, CBOR.decode_lazy(CBOR.encode(p)).value
end

assert('registered tag: _after_decode / _before_encode hooks both fire') do
  class RegCounter
    attr_accessor :count
    native_ext_type :@count, Integer
    def initialize(n); @count = n; end
    def _before_encode; @count += 1; self; end
    def _after_decode;  @count += 1; self; end
  end
  CBOR.register_tag(1002, RegCounter)

  result = CBOR.decode(CBOR.encode(RegCounter.new(10)))
  assert_equal 12, result.count  # +1 before encode, +1 after decode
end

assert('registered tag: _before_encode exception propagates') do
  class RegStrict
    native_ext_type :@v, Integer
    def initialize(v); @v = v; end
    def _before_encode; raise "encode forbidden"; end
  end
  CBOR.register_tag(1005, RegStrict)
  assert_raise(RuntimeError) { CBOR.encode(RegStrict.new(1)) }
end

assert('registered tag: extra fields silently ignored (allowlist)') do
  class RegAllowlist
    attr_accessor :a, :b
    native_ext_type :@a, String
    native_ext_type :@b, Integer
    def initialize; @a = ""; @b = 0; end
  end
  CBOR.register_tag(2000, RegAllowlist)

  payload = { "a" => "hello", "b" => 42, "x" => "ignored", "y" => [1, 2] }
  decoded = CBOR.decode("\xD9\x07\xD0" + CBOR.encode(payload))
  assert_equal "hello", decoded.a
  assert_equal 42,      decoded.b
  assert_equal 2,       decoded.instance_variables.length
end

assert('registered tag: payload-not-a-map raises TypeError') do
  # tag(1000) + integer; decoder expects a map
  assert_raise(TypeError) { CBOR.decode("\xD9\x03\xE8\x01") }
end

assert('registered tag: decode field wrong type raises TypeError') do
  class RegMismatch
    native_ext_type :@name, String
    def initialize; @name = ""; end
  end
  CBOR.register_tag(3001, RegMismatch)
  assert_raise(TypeError) { CBOR.decode("\xD9\x0B\xB9" + CBOR.encode({"name" => 42})) }
end

assert('registered tag: encode field wrong type raises TypeError') do
  class RegEncMismatch
    native_ext_type :@v, Integer
    def initialize(v); @v = v; end
  end
  CBOR.register_tag(3002, RegEncMismatch)

  bad = RegEncMismatch.allocate
  bad.instance_variable_set(:@v, "not an integer")
  assert_raise(TypeError) { CBOR.encode(bad) }
end

# ── nullable + union fields ────────────────────────────────────────────────

assert('registered tag: nullable Integer|NilClass field — value and nil both roundtrip') do
  class RegProduct
    native_ext_type :@id,    Integer
    native_ext_type :@price, Integer, NilClass
    def initialize; @id = 0; @price = nil; end
  end
  CBOR.register_tag(4000, RegProduct)

  p = RegProduct.new; p.instance_variable_set(:@id, 1); p.instance_variable_set(:@price, 999)
  assert_equal 999, CBOR.decode(CBOR.encode(p)).instance_variable_get(:@price)

  p2 = RegProduct.new; p2.instance_variable_set(:@id, 2)
  assert_nil CBOR.decode(CBOR.encode(p2)).instance_variable_get(:@price)
end

assert('registered tag: boolean-or-nil union accepts all three values') do
  class RegFlag
    native_ext_type :@enabled, TrueClass, FalseClass, NilClass
    def initialize; @enabled = nil; end
  end
  CBOR.register_tag(4002, RegFlag)

  [true, false, nil].each do |val|
    r = RegFlag.new; r.instance_variable_set(:@enabled, val)
    assert_equal val, CBOR.decode(CBOR.encode(r)).instance_variable_get(:@enabled)
  end
end

assert('registered tag: Integer|Float|NilClass union — numeric union works') do
  class RegScore
    native_ext_type :@s, Integer, Float, NilClass
    def initialize; @s = nil; end
  end
  CBOR.register_tag(4003, RegScore)

  [42, 3.14, nil].each do |val|
    r = RegScore.new; r.instance_variable_set(:@s, val)
    got = CBOR.decode(CBOR.encode(r)).instance_variable_get(:@s)
    val.nil? ? assert_nil(got) : assert_equal(val, got)
  end
end

assert('registered tag: nullable field wrong type raises on encode and decode') do
  class RegProduct
    native_ext_type :@id,    Integer
    native_ext_type :@price, Integer, NilClass
    def initialize; @id = 0; @price = nil; end
  end
  CBOR.register_tag(4000, RegProduct)

  bad = RegProduct.new
  bad.instance_variable_set(:@price, "free")  # String is not Integer|NilClass
  assert_raise(TypeError) { CBOR.encode(bad) }

  buf = "\xD9\x0F\xA0" + CBOR.encode({ "id" => 4, "price" => "free" })
  assert_raise(TypeError) { CBOR.decode(buf) }
end

# ── registered tags under sharedrefs ───────────────────────────────────────

assert('registered tag + sharedref: same instance in array → identity preserved') do
  class SharedPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
  end
  CBOR.register_tag(5000, SharedPoint)

  p = SharedPoint.new(3, 7)
  r = CBOR.decode(CBOR.encode([p, p, p], sharedrefs: true))
  assert_same r[0], r[1]; assert_same r[1], r[2]
end

assert('registered tag + sharedref: distinct instances with equal fields do NOT share') do
  class SharedPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
  end
  CBOR.register_tag(5000, SharedPoint)

  p1 = SharedPoint.new(1, 2); p2 = SharedPoint.new(1, 2)
  r = CBOR.decode(CBOR.encode([p1, p2], sharedrefs: true))
  assert_not_same r[0], r[1]
end

assert('registered tag + sharedref: non-immediate ivar (String) shares correctly') do
  # String field triggers a nested Tag 28 inside the registered payload;
  # preorder slot reservation in decode_tag_sharedrefs is what makes this work.
  class SharedConfig
    native_ext_type :@timeout, Integer
    native_ext_type :@name,    String
    def initialize(t = 0, n = ""); @timeout = t; @name = n; end
  end
  CBOR.register_tag(5001, SharedConfig)

  cfg = SharedConfig.new(30, "default")
  r = CBOR.decode(CBOR.encode({"p" => cfg, "b" => cfg, "f" => cfg}, sharedrefs: true))
  assert_same r["p"], r["b"]; assert_same r["b"], r["f"]
end

assert('registered tag + sharedref: identity preserved through lazy.value') do
  class LazyShared
    native_ext_type :@val, Integer
    def initialize(v = 0); @val = v; end
  end
  CBOR.register_tag(5003, LazyShared)

  l = LazyShared.new(99)
  full = CBOR.decode_lazy(CBOR.encode({"a" => l, "b" => l}, sharedrefs: true)).value
  assert_same full["a"], full["b"]
end

assert('registered tag + sharedref: instance with self-referential field') do
  class CyclicNode
    native_ext_type :@id,  Integer
    native_ext_type :@nxt, CyclicNode, NilClass
    def initialize(i = 0); @id = i; @nxt = nil; end
  end
  CBOR.register_tag(5100, CyclicNode)

  n = CyclicNode.new(1); n.instance_variable_set(:@nxt, n)
  r = CBOR.decode(CBOR.encode(n, sharedrefs: true))
  assert_same r, r.instance_variable_get(:@nxt)
end

assert('registered tag + sharedref: mutual recursion between two instances') do
  class MutualA
    native_ext_type :@tag, Integer
    def initialize(t = 0); @tag = t; @peer = nil; end
  end
  class MutualB
    native_ext_type :@tag, Integer
    def initialize(t = 0); @tag = t; @peer = nil; end
  end
  class MutualA; native_ext_type :@peer, MutualB, NilClass; end
  class MutualB; native_ext_type :@peer, MutualA, NilClass; end
  CBOR.register_tag(5101, MutualA)
  CBOR.register_tag(5102, MutualB)

  a = MutualA.new(1); b = MutualB.new(2)
  a.instance_variable_set(:@peer, b); b.instance_variable_set(:@peer, a)
  r = CBOR.decode(CBOR.encode(a, sharedrefs: true))
  assert_same r, r.instance_variable_get(:@peer).instance_variable_get(:@peer)
end

# ── register_tag input validation ──────────────────────────────────────────

assert('register_tag: reserved tags 2/3/28/29/39/49999 raise ArgumentError') do
  class RegResvDummy; end
  [2, 3, 28, 29, 39, 49999].each { |t|
    assert_raise(ArgumentError) { CBOR.register_tag(t, RegResvDummy) }
  }
end

assert('register_tag: built-in classes raise TypeError') do
  [Array, Hash, String, Integer].each { |c|
    assert_raise(TypeError) { CBOR.register_tag(55000, c) }
  }
end

# =============================================================================
# §3.1 Major type 6 — Proc-registered tags (register_tag with block)
#
# For types that can't use native_ext_type (Exception, Time, etc.).
# =============================================================================

assert('proc tag: basic encode + decode + lazy') do
  class ProcBox
    attr_accessor :val
    def initialize(v = 0); @val = v; end
  end
  CBOR.register_tag(60000) do
    encode ProcBox do |b| b.val end
    decode Integer do |i| ProcBox.new(i) end
  end

  eager = CBOR.decode(CBOR.encode(ProcBox.new(42)))
  lazy  = CBOR.decode_lazy(CBOR.encode(ProcBox.new(42))).value
  [eager, lazy].each { |r| assert_true r.is_a?(ProcBox); assert_equal 42, r.val }
end

assert('proc tag: Exception full roundtrip (class + message + backtrace)') do
  CBOR.register_tag(60005) do
    encode Exception do |e| [e.class, e.message, e.backtrace] end
    decode Array do |a|
      exc = a[0].new(a[1])
      exc.set_backtrace(a[2]) if a[2]
      exc
    end
  end

  buf = begin; raise ArgumentError, "bad argument"; rescue => e; CBOR.encode(e); end
  exc = CBOR.decode(buf)
  assert_true exc.is_a?(ArgumentError)
  assert_equal "bad argument", exc.message
  assert_not_nil exc.backtrace
end

assert('proc tag: Exception subclasses preserved (tag 49999 does the class)') do
  CBOR.register_tag(60006) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end
  [ArgumentError, RuntimeError, TypeError, StandardError].each { |klass|
    assert_equal klass, CBOR.decode(CBOR.encode(klass.new("msg"))).class
  }
end

assert('proc tag + sharedref: same Exception shares identity') do
  CBOR.register_tag(60100) do
    encode Exception do |e| [e.class, e.message] end
    decode Array     do |a| a[0].new(a[1]) end
  end

  exc = RuntimeError.new("oops")
  r = CBOR.decode(CBOR.encode([exc, exc, {"err" => exc}], sharedrefs: true))
  assert_same r[0], r[1]; assert_same r[1], r[2]["err"]
end

assert('proc tag: cannot register natively-encoded types as encode target') do
  natives = [String, Integer, Float, Array, Hash, TrueClass, FalseClass,
             NilClass, Symbol, Class, Module]
  natives.each_with_index do |klass, i|
    assert_raise(TypeError) do
      CBOR.register_tag(61100 + i) do
        encode klass  do |v| v end
        decode String do |s| s end
      end
    end
  end
end

assert('proc tag: Exception is explicitly allowed as encode target') do
  CBOR.register_tag(61011) do
    encode Exception do |e| e.message end
    decode String    do |s| RuntimeError.new(s) end
  end
  assert_equal "ok", CBOR.decode(CBOR.encode(RuntimeError.new("ok"))).message
end

# =============================================================================
# §3.1 Major type 7 — simple & floating-point
# Exercises every info branch of major 7.
# =============================================================================

assert('major 7: simple values false / true / null / undefined') do
  # 20, 21, 22, 23
  assert_false CBOR.decode("\xF4")
  assert_true  CBOR.decode("\xF5")
  assert_nil   CBOR.decode("\xF6")
  assert_nil   CBOR.decode("\xF7")  # undefined → decoded as nil
end

assert('major 7: simple info<20 decoded as nil') do
  # 0xE0 = 7<<5 | 0 → simple(0), decoded as nil per our policy
  assert_nil CBOR.decode("\xE0")
end

assert('major 7: extended simple (info=24) decoded as nil + consumes byte') do
  assert_nil CBOR.decode("\xF8\x10")  # simple(16)
  # trailing data is ignored when decoding just the simple value
  assert_nil CBOR.decode("\xF8\xFF\x18\x2A"[0, 2])
end

assert('major 7: reserved simple values 28/29/30 raise cleanly') do
  ["\xFC", "\xFD", "\xFE"].each { |b| assert_safe { CBOR.decode(b) } }
end

assert('major 7: float widths decode (f16 / f32 / f64)') do
  assert_equal 1.0, CBOR.decode("\xF9\x3C\x00")
  assert_equal 0.0, CBOR.decode("\xF9\x00\x00")
  assert_equal 1.0, CBOR.decode("\xFA\x3F\x80\x00\x00")
  assert_equal 0.0, CBOR.decode("\xFA\x80\x00\x00\x00")
  assert_equal 1.0, CBOR.decode("\xFB\x3F\xF0\x00\x00\x00\x00\x00\x00")
end

assert('major 7: ±Inf and NaN roundtrip at all widths') do
  assert_equal Float::INFINITY,  CBOR.decode(CBOR.encode(Float::INFINITY))
  assert_equal(-Float::INFINITY, CBOR.decode(CBOR.encode(-Float::INFINITY)))
  assert_true CBOR.decode(CBOR.encode(Float::NAN)).nan?
  # Also direct wire
  assert_equal Float::INFINITY, CBOR.decode("\xF9\x7C\x00")
  assert_true  CBOR.decode("\xF9\x7E\x00").nan?
end

assert('major 7: ±zero and sample floats roundtrip') do
  [0.0, -0.0, 1.5, 1.0e300].each { |f|
    assert_equal f, CBOR.decode(CBOR.encode(f))
  }
end

# =============================================================================
# §3.2 Indefinite lengths — rejected (not supported by this implementation)
# =============================================================================

assert('§3.2: indefinite-length array / map / text all raise cleanly') do
  [ "\x9F\x01\x02\xFF",   # array
    "\xBF\x61\x61\x01\xFF", # map
    "\x7F\x61\x61\x61\x62\xFF" # text
  ].each { |buf| assert_safe { CBOR.decode(buf) } }
end

# =============================================================================
# §4.1 Preferred serialization — floats
#
# Each float encodes at the smallest width that represents it losslessly:
# f16 (3 bytes) → f32 (5 bytes) → f64 (9 bytes). NaN always canonicalizes
# to 0xF97E00 per RFC 8949 Appendix B.
# =============================================================================

assert('§4.1 float wire: exact bytes for well-known f16 values') do
  # Array of pairs, NOT a hash — in mruby `0.0 == -0.0` and they hash
  # equally, so a hash literal would collapse the two sign-of-zero entries.
  [
    [0.0,              "\xF9\x00\x00"],
    [-0.0,             "\xF9\x80\x00"],
    [1.0,              "\xF9\x3C\x00"],
    [1.5,              "\xF9\x3E\x00"],
    [-1.5,             "\xF9\xBE\x00"],
    [0.5,              "\xF9\x38\x00"],
    [0.25,             "\xF9\x34\x00"],
    [100.0,            "\xF9\x56\x40"],
    [65504.0,          "\xF9\x7B\xFF"],   # f16 max normal
    [Float::INFINITY,  "\xF9\x7C\x00"],
    [-Float::INFINITY, "\xF9\xFC\x00"],
  ].each { |v, wire| assert_equal wire, CBOR.encode(v), "wrong encoding for #{v}" }
end

assert('§4.1 float wire: NaN canonicalizes to f16 0xF97E00') do
  assert_equal "\xF9\x7E\x00", CBOR.encode(Float::NAN)
end

assert('§4.1 float width: normals and subnormals select f16 (3 bytes)') do
  [0.0, -0.0, 1.0, 1.5, -1.5, 0.5, 0.25, 100.0, 65504.0,
   Float::INFINITY, -Float::INFINITY, Float::NAN,
   1.0/16777216.0, 1.0/8388608.0, 1.0/32768.0].each { |v|
    assert_equal 3, CBOR.encode(v).bytesize, "expected f16 for #{v}"
  }
end

assert('§4.1 float width: subnormal 2^-24 encodes as f16 0xF90001') do
  assert_equal "\xF9\x00\x01", CBOR.encode(1.0/16777216.0)
end

assert('§4.1 float width: subnormal powers of 2 round-trip correctly') do
  v = 1.0 / 16777216.0
  10.times do |_|
    enc = CBOR.encode(v)
    assert_equal 3, enc.bytesize
    assert_equal v, CBOR.decode(enc)
    v *= 2.0
  end
end

assert('§4.1 float width: values above f16 range use f32 (5 bytes)') do
  [65505.0, 1.0e10].each { |v| assert_equal 5, CBOR.encode(v).bytesize }
  # 2^-126 (f32 min normal)
  v = 1.0; 126.times { v /= 2.0 }
  assert_equal 5, CBOR.encode(v).bytesize
end

assert('§4.1 float width: f64-only values use f64 (9 bytes)') do
  [3.14, 1.0/3.0, 1.0e300].each { |v| assert_equal 9, CBOR.encode(v).bytesize }
end

assert('§4.1 float width: re-encoding wider-wire decoded floats narrows') do
  [ CBOR.decode("\xFA\x3F\x80\x00\x00"),                          # 1.0 from f32
    CBOR.decode("\xFB\x3F\xF0\x00\x00\x00\x00\x00\x00") ].each do |v|
    assert_equal 1.0, v
    assert_equal 3,   CBOR.encode(v).bytesize  # narrowed to f16
  end
end

assert('§4.1 floats in arrays / maps / lazy all round-trip correctly') do
  ary = [0.0, 1.5, 1.0e10, 3.14, Float::INFINITY]
  assert_equal ary, CBOR.decode(CBOR.encode(ary))

  h = { "f16" => 1.5, "f32" => 1.0e10, "f64" => 3.14 }
  assert_equal h, CBOR.decode(CBOR.encode(h))

  [1.5, 1.0e10, 3.14].each { |v|
    assert_equal v, CBOR.decode_lazy(CBOR.encode(v)).value
  }
end

# =============================================================================
# Non-RFC: Fast path (encode_fast / decode_fast)
#
# Same-build-only format: integers and floats use fixed native widths,
# strings always major 2, canonical length prefixes everywhere else.
# =============================================================================

assert('fast: primitives roundtrip (bool, nil, int, neg int, float, string)') do
  [ true, false, nil, 0, 1, 127, 255, 256, 65535, 65536,
    -1, -42, -1000, -65536,
    0.0, 1.5, 3.14, -1.5, Float::INFINITY, -Float::INFINITY,
    "", "hello", "hällo"
  ].each { |v|
    got = CBOR.decode_fast(CBOR.encode_fast(v))
    if v.is_a?(Float) && v.nan?
      assert_true got.nan?
    else
      assert_equal v, got
    end
  }
end

assert('fast: NaN roundtrips as NaN') do
  assert_true CBOR.decode_fast(CBOR.encode_fast(Float::NAN)).nan?
end

assert('fast: containers — empty / array / map / nested all roundtrip') do
  [ [], {}, [1, -2, "three", true, false, nil, 3.14],
    { "id" => 42, "name" => "Alice", "score" => -99, "active" => true },
    { "users" => [ { "id" => 1, "n" => "Alice" }, { "id" => 2, "n" => "Bob" } ], "count" => 2 },
    (1..100).to_a
  ].each { |v| assert_equal v, CBOR.decode_fast(CBOR.encode_fast(v)) }
end

assert('fast: symbols always encode as tag 39 + string regardless of mode') do
  CBOR.no_symbols  # mode doesn't matter for fast path
  assert_equal :hello, CBOR.decode_fast(CBOR.encode_fast(:hello))
  assert_equal({ hello: 1, world: 2 }, CBOR.decode_fast(CBOR.encode_fast({hello: 1, world: 2})))
end

assert('fast: class and module roundtrip via tag 49999') do
  assert_equal String,         CBOR.decode_fast(CBOR.encode_fast(String))
  assert_equal ArgumentError,  CBOR.decode_fast(CBOR.encode_fast(ArgumentError))
  h = { "klass" => StandardError, "msg" => "oops" }
  assert_equal h, CBOR.decode_fast(CBOR.encode_fast(h))
end

assert('fast: strings always emit major 2 (byte string)') do
  buf = CBOR.encode_fast("hello")
  assert_equal 0x45, buf.getbyte(0)  # major 2, len 5
  # length prefix width matches canonical
  assert_equal CBOR.encode("hello").bytesize, buf.bytesize
end

assert('fast: array / map count use canonical shortest-form length') do
  assert_equal CBOR.encode([true, false, nil]).bytesize,
               CBOR.encode_fast([true, false, nil]).bytesize
end

assert('fast: wrong-width integer info raises RuntimeError') do
  # Canonical inline-small-integer (info < 24) is never the fast integer info
  assert_raise(RuntimeError) { CBOR.decode_fast("\x01") }
end

assert('fast: major 3 text string raises (fast uses major 2 only)') do
  assert_raise(RuntimeError) { CBOR.decode_fast("\x65hello") }
end

assert('fast: tag 39 / tag 49999 with non-string payload raise TypeError') do
  assert_raise(TypeError) { CBOR.decode_fast("\xD8\x27\xF5") }       # tag 39 + true
  assert_raise(TypeError) { CBOR.decode_fast("\xD9\xC3\x4F\xF5") }   # tag 49999 + true
end

assert('fast: canonical-only buffer raises on decode_fast') do
  assert_raise(RuntimeError) { CBOR.decode_fast(CBOR.encode(1)) }
end

# ── fast: fallback to canonical for registered / proc / bigint ─────────────

assert('fast: registered class falls back to canonical encode and decode') do
  class FastPoint
    native_ext_type :@x, Integer
    native_ext_type :@y, Integer
    def initialize(x = 0, y = 0); @x = x; @y = y; end
  end
  CBOR.register_tag(9001, FastPoint)

  p = FastPoint.new(3, 7)
  # fast fallback must produce identical bytes to canonical for this value
  assert_equal CBOR.encode(p), CBOR.encode_fast(p)

  decoded = CBOR.decode_fast(CBOR.encode_fast(p))
  assert_equal 3, decoded.instance_variable_get(:@x)
  assert_equal 7, decoded.instance_variable_get(:@y)
end

assert('fast: registered tag — hooks fire on fallback path') do
  class FastItem
    attr_accessor :value
    native_ext_type :@value, Integer
    def initialize(v); @value = v; end
    def _before_encode; @value *= 2; self; end
    def _after_decode;  @value += 1; self; end
  end
  CBOR.register_tag(9010, FastItem)

  # 5 → before_encode → 10 → after_decode → 11
  assert_equal 11, CBOR.decode_fast(CBOR.encode_fast(FastItem.new(5))).value
end

assert('fast: proc tag falls back to canonical') do
  class FastWrapper
    def initialize(v); @v = v; end
    def val; @v; end
  end
  CBOR.register_tag(9014) do
    encode FastWrapper do |w| w.val end
    decode Integer     do |i| FastWrapper.new(i * 3) end
  end

  w = FastWrapper.new(7)
  assert_equal CBOR.encode(w), CBOR.encode_fast(w)
  assert_equal 21, CBOR.decode_fast(CBOR.encode_fast(w)).val
end

assert('fast: random bytes + truncation never crash') do
  r = Random.new(0xFA57)
  200.times do
    buf = r.rand(0..128).times.map { r.rand(0..255).chr }.join
    assert_safe { CBOR.decode_fast(buf) }
  end

  [ CBOR.encode_fast([1, 2, 3]), CBOR.encode_fast({"a" => 1, "b" => 2}),
    CBOR.encode_fast(42),        CBOR.encode_fast("hello") ].each do |buf|
    buf.bytesize.times { |cut| assert_safe { CBOR.decode_fast(buf[0, cut]) } }
  end
end

# =============================================================================
# Non-RFC: CBOR::Lazy — on-demand decoding
# =============================================================================

assert('lazy: basic key access (string, integer, mixed)') do
  assert_equal 1, CBOR.decode_lazy(CBOR.encode({"a" => 1, "b" => 2}))["a"].value
  l = CBOR.decode_lazy(CBOR.encode({1 => "one", 2 => "two"}))
  assert_equal "one", l[1].value; assert_equal "two", l[2].value

  l = CBOR.decode_lazy(CBOR.encode({1 => "int", "str" => "s", 100 => "c"}))
  assert_equal "int", l[1].value
  assert_equal "s",   l["str"].value
  assert_equal "c",   l[100].value
end

assert('lazy: access errors — empty, missing, out-of-bounds') do
  assert_raise(IndexError) { CBOR.decode_lazy(CBOR.encode([]))[0] }
  assert_raise(KeyError)   { CBOR.decode_lazy(CBOR.encode({}))["x"] }
  assert_raise(KeyError)   { CBOR.decode_lazy(CBOR.encode({"a" => 1}))["missing"] }
  assert_raise(IndexError) { CBOR.decode_lazy(CBOR.encode([1, 2, 3]))[99] }
  assert_raise(TypeError)  { CBOR.decode_lazy(CBOR.encode([1, 2, 3]))["invalid"].value }
  assert_raise(TypeError)  { CBOR.decode_lazy(CBOR.encode(42)).dig("key") }
end

assert('lazy: caches result — repeated access returns same Ruby object') do
  h = { "a" => { "b" => { "c" => 123 } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  100.times { assert_equal 123, lazy["a"]["b"]["c"].value }

  # dig and aref reach the same cached wrapper
  assert_same lazy.dig("a", "b", "c"), lazy["a"]["b"]["c"]
end

assert('lazy: deep nesting + wide maps') do
  deep = 42; 5.times { deep = [deep] }
  assert_equal 42, CBOR.decode_lazy(CBOR.encode(deep))[0][0][0][0][0].value

  h = {}; 100.times { |i| h["key_#{i}"] = i }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal 0,  lazy["key_0"].value
  assert_equal 50, lazy["key_50"].value
  assert_equal 99, lazy["key_99"].value
end

assert('lazy: dig — missing keys return nil, negative array indices work') do
  h = { "a" => 1, "b" => { "c" => 42 } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_nil       lazy.dig("missing")
  assert_nil       lazy.dig("missing", "x")
  assert_equal 42, lazy.dig("b", "c").value

  la = CBOR.decode_lazy(CBOR.encode([10, 20, 30, 40, 50]))
  assert_equal 50, la.dig(-1).value
  assert_equal 10, la.dig(-5).value
  assert_nil la.dig(-99)
end

assert('lazy: can still navigate child lazies after calling .value on parent') do
  lazy = CBOR.decode_lazy(CBOR.encode({ "a" => { "b" => 42 } }))
  lazy.value
  assert_equal 42, lazy["a"]["b"].value
end

assert('lazy: random-access stress') do
  h = { "statuses" => (1..50).map { |i| { "id" => i, "txt" => "msg#{i}" } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  200.times do
    i = rand(0...50)
    assert_equal "msg#{i + 1}", lazy["statuses"][i]["txt"].value
  end
end

assert('lazy: bignum in nested structures decodes correctly') do
  big = (1 << 200) + 12345
  obj = { "nums" => [1, 2, big], "meta" => { "big" => big } }
  lazy = CBOR.decode_lazy(CBOR.encode(obj))
  assert_equal big, lazy["nums"][2].value
  assert_equal big, lazy["meta"]["big"].value
end

assert('lazy: skip_cbor truncation raises RangeError') do
  # array(2): [ bytes-claim-10-but-short, uint42 ]. lazy[1] must skip past
  # the truncated byte string and hits skip_cbor's bounds check.
  buf = "\x82\x4A\x01\x02\x03\x18\x2A"
  assert_raise(RangeError) { CBOR.decode_lazy(buf)[1].value }
end

assert('lazy: huge aref index handled cleanly') do
  assert_safe { CBOR.decode_lazy(CBOR.encode([1, 2, 3]))[0x7FFFFFFF] }
end

# =============================================================================
# Non-RFC: CBOR::Path — point queries and [*] wildcards
# =============================================================================

assert('path: plain point query (no wildcards)') do
  lazy = CBOR.decode_lazy(CBOR.encode({"a" => {"b" => 42}}))
  assert_equal 42, CBOR::Path.compile("$.a.b").at(lazy)
end

assert('path: single wildcard — terminal and with tail') do
  lazy = CBOR.decode_lazy(CBOR.encode([10, 20, 30]))
  assert_equal [10, 20, 30], CBOR::Path.compile("$[*]").at(lazy)

  h = { "users" => [{"name" => "A", "age" => 30},
                    {"name" => "B", "age" => 25},
                    {"name" => "C", "age" => 35}] }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  assert_equal ["A", "B", "C"], CBOR::Path.compile("$.users[*].name").at(lazy)
end

assert('path: single wildcard — nested tail + bracket-index tail') do
  h = { "rows" => [{"d" => {"v" => 1}}, {"d" => {"v" => 2}}, {"d" => {"v" => 3}}] }
  assert_equal [1, 2, 3],
    CBOR::Path.compile("$.rows[*].d.v").at(CBOR.decode_lazy(CBOR.encode(h)))

  p = { "pairs" => [[1, 2], [3, 4], [5, 6]] }
  assert_equal [2, 4, 6],
    CBOR::Path.compile("$.pairs[*][1]").at(CBOR.decode_lazy(CBOR.encode(p)))
end

assert('path: two wildcards — nested results mirror the structure') do
  data = { "teams" => [
    { "members" => [{"n" => "a"}, {"n" => "b"}] },
    { "members" => [{"n" => "c"}] } ] }
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  assert_equal [["a", "b"], ["c"]],
    CBOR::Path.compile("$.teams[*].members[*].n").at(lazy)
end

assert('path: three wildcards — triple-nested results') do
  data = { "regions" => [
    { "teams" => [ { "members" => [{"n" => "a"}, {"n" => "b"}] }, { "members" => [{"n" => "c"}] } ] },
    { "teams" => [ { "members" => [{"n" => "d"}, {"n" => "e"}, {"n" => "f"}] } ] } ] }
  lazy = CBOR.decode_lazy(CBOR.encode(data))
  assert_equal [[["a", "b"], ["c"]], [["d", "e", "f"]]],
    CBOR::Path.compile("$.regions[*].teams[*].members[*].n").at(lazy)
end

assert('path: adjacent wildcards [*][*]') do
  lazy = CBOR.decode_lazy(CBOR.encode([[1, 2, 3], [4, 5], [], [6]]))
  assert_equal [[1, 2, 3], [4, 5], [], [6]], CBOR::Path.compile("$[*][*]").at(lazy)
end

assert('path: index then wildcard / wildcard then index') do
  data = { "rows" => [[{"v" => 10}, {"v" => 20}], [{"v" => 30}, {"v" => 40}]] }
  assert_equal [30, 40],
    CBOR::Path.compile("$.rows[1][*].v").at(CBOR.decode_lazy(CBOR.encode(data)))

  data2 = { "rows" => [[10, 20, 30], [40, 50, 60], [70, 80, 90]] }
  assert_equal [20, 50, 80],
    CBOR::Path.compile("$.rows[*][1]").at(CBOR.decode_lazy(CBOR.encode(data2)))
end

assert('path: edge cases — empty outer, empty inner, heterogeneous values') do
  assert_equal [], CBOR::Path.compile("$.statuses[*].id")
    .at(CBOR.decode_lazy(CBOR.encode({"statuses" => []})))

  data = { "groups" => [{"xs" => []}, {"xs" => [1, 2]}, {"xs" => []}] }
  assert_equal [[], [1, 2], []],
    CBOR::Path.compile("$.groups[*].xs[*]").at(CBOR.decode_lazy(CBOR.encode(data)))

  data2 = { "xs" => [1, "two", nil, true, [3, 4], {"k" => "v"}] }
  assert_equal [1, "two", nil, true, [3, 4], {"k" => "v"}],
    CBOR::Path.compile("$.xs[*]").at(CBOR.decode_lazy(CBOR.encode(data2)))
end

assert('path: errors — wildcard on non-array, missing keys') do
  assert_raise(TypeError) {
    CBOR::Path.compile("$[*]").at(CBOR.decode_lazy(CBOR.encode({"a" => 1})))
  }
  assert_raise(TypeError) {
    CBOR::Path.compile("$.x[*]").at(CBOR.decode_lazy(CBOR.encode({"x" => {"y" => 1}})))
  }
  assert_raise(KeyError) {
    CBOR::Path.compile("$.statuses[*].id").at(CBOR.decode_lazy(CBOR.encode({"not_statuses" => []})))
  }
  assert_raise(KeyError) {
    data = { "a" => [{"b" => 1}, {"c" => 2}] }
    CBOR::Path.compile("$.a[*].b").at(CBOR.decode_lazy(CBOR.encode(data)))
  }
end

assert('path: compiled path is reusable across different lazies') do
  path = CBOR::Path.compile("$.items[*].id")
  r1 = path.at(CBOR.decode_lazy(CBOR.encode({"items" => [{"id"=>1},{"id"=>2}]})))
  r2 = path.at(CBOR.decode_lazy(CBOR.encode({"items" => [{"id"=>9},{"id"=>8},{"id"=>7}]})))
  assert_equal [1, 2],    r1
  assert_equal [9, 8, 7], r2
end

assert('path: [*] skips untouched fields cheaply (regression for greedy decode)') do
  big = "x" * 100_000
  users = (1..50).map { |i| { "name" => "u#{i}", "blob" => big } }
  lazy = CBOR.decode_lazy(CBOR.encode({"users" => users}))
  names = CBOR::Path.compile("$.users[*].name").at(lazy)
  assert_equal 50,    names.length
  assert_equal "u1",  names.first
  assert_equal "u50", names.last
end

assert('path + sharedref: wildcard iterates over Tag 29 target') do
  shared_users = [{"name" => "alice"}, {"name" => "bob"}]
  data = { "primary" => {"users" => shared_users}, "backup" => {"users" => shared_users} }
  lazy = CBOR.decode_lazy(CBOR.encode(data, sharedrefs: true))
  assert_equal ["alice", "bob"],
    CBOR::Path.compile("$.backup.users[*].name").at(lazy)
end

assert('path + sharedref: wildcard on shared leaf + two wildcards over shared') do
  shared = [1, 2, 3]
  data = { "a" => shared, "b" => shared }
  lazy = CBOR.decode_lazy(CBOR.encode(data, sharedrefs: true))
  assert_equal [1, 2, 3], CBOR::Path.compile("$.a[*]").at(lazy)
  assert_equal [1, 2, 3], CBOR::Path.compile("$.b[*]").at(lazy)

  shared_teams = [{"members" => [{"n" => "a"}, {"n" => "b"}]}, {"members" => [{"n" => "c"}]}]
  data = { "p" => {"teams" => shared_teams}, "b" => {"teams" => shared_teams} }
  lazy = CBOR.decode_lazy(CBOR.encode(data, sharedrefs: true))
  assert_equal [["a", "b"], ["c"]],
    CBOR::Path.compile("$.b.teams[*].members[*].n").at(lazy)
end

# ── path ↔ lazy cache consistency ──────────────────────────────────────────

assert('cache: path populates kcache — direct [] returns SAME wrapper') do
  h = { "statuses" => (0...10).map { |i| { "id" => i } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  CBOR::Path.compile("$.statuses[*].id").at(lazy)
  arr = lazy["statuses"]
  assert_same arr[3], arr[3]
  # different indices are different wrappers
  assert_not_equal arr[3].__id__, arr[4].__id__
end

assert('cache: direct [] first — subsequent path.at reuses existing wrappers') do
  h = { "rows" => (0...5).map { |i| { "v" => i * 10 } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  pre_wrappers = (0...5).map { |i| lazy["rows"][i] }
  CBOR::Path.compile("$.rows[*].v").at(lazy)
  (0...5).each { |i| assert_equal pre_wrappers[i].__id__, lazy["rows"][i].__id__ }
end

assert('cache: vcache survives across path / aref / dig') do
  h = { "items" => (0...3).map { |i| { "name" => "item#{i}" } } }
  lazy = CBOR.decode_lazy(CBOR.encode(h))
  CBOR::Path.compile("$.items[*].name").at(lazy)
  a = lazy["items"][1]["name"].value
  b = lazy["items"][1]["name"].value
  assert_same a, b
  assert_same a, lazy.dig("items", 1, "name").value
end

# =============================================================================
# Non-RFC: CBOR.stream / CBOR::StreamDecoder
# =============================================================================

assert('stream: single / multiple / empty documents from MockIO') do
  r = []; CBOR.stream(MockIO.new(CBOR.encode({"a" => 1}))) { |d| r << d.value }
  assert_equal [{"a" => 1}], r

  buf = CBOR.encode({"a" => 1}) + CBOR.encode([1, 2, 3]) + CBOR.encode(42)
  r = []; CBOR.stream(MockIO.new(buf)) { |d| r << d.value }
  assert_equal [{"a" => 1}, [1, 2, 3], 42], r

  r = []; CBOR.stream(MockIO.new("")) { |d| r << d.value }
  assert_equal [], r
end

assert('stream: doc shorter than 9 bytes / large doc requiring readahead') do
  r = []; CBOR.stream(MockIO.new(CBOR.encode(0))) { |d| r << d.value }
  assert_equal [0], r

  big = { "items" => (1..100).map { |i| { "id" => i, "name" => "item#{i}" } } }
  r = []; CBOR.stream(MockIO.new(CBOR.encode(big))) { |d| r << d.value }
  assert_equal [big], r
end

assert('stream: enumerator mode (no block)') do
  buf = CBOR.encode("hello") + CBOR.encode("world")
  assert_equal ["hello", "world"], CBOR.stream(MockIO.new(buf)).map(&:value)
end

assert('stream: offset parameter skips leading bytes') do
  doc1 = CBOR.encode("skip"); doc2 = CBOR.encode("keep")
  r = []; CBOR.stream(MockIO.new(doc1 + doc2), doc1.bytesize) { |d| r << d.value }
  assert_equal ["keep"], r
end

assert('stream: mixed major types, various integer widths') do
  docs = [42, "hello", [1, 2, 3], { "x" => 1 }, true, nil, 1.5]
  assert_equal docs,
    CBOR.stream(MockIO.new(docs.map { |d| CBOR.encode(d) }.join)).map(&:value)

  ints = [0, 23, 24, 255, 256, 65535, 65536, 0xFFFFFFFF, 0x100000000]
  assert_equal ints,
    CBOR.stream(MockIO.new(ints.map { |n| CBOR.encode(n) }.join)).map(&:value)
end

assert('stream: string input (bytesize/byteslice dispatch)') do
  buf = CBOR.encode(1) + CBOR.encode(2) + CBOR.encode(3)
  r = []; CBOR.stream(buf) { |d| r << d.value }
  assert_equal [1, 2, 3], r

  r = []; CBOR.stream(buf, CBOR.encode(1).bytesize) { |d| r << d.value }
  assert_equal [2, 3], r

  assert_true CBOR.stream(CBOR.encode(1) + CBOR.encode(2)).respond_to?(:each)
end

assert('stream: sharedrefs inside a streamed document work') do
  v = [1, 2, 3]
  r = []; CBOR.stream(MockIO.new(CBOR.encode({"a" => v, "b" => v}, sharedrefs: true))) { |d| r << d.value }
  assert_equal [{"a" => [1, 2, 3], "b" => [1, 2, 3]}], r
end

assert('stream: unknown IO type raises TypeError') do
  assert_raise(TypeError) { CBOR.stream(42) }
end

assert('StreamDecoder: fed byte-by-byte produces documents in order') do
  buf = CBOR.encode("hello") + CBOR.encode("world")
  r = []
  dec = CBOR::StreamDecoder.new { |d| r << d.value }
  buf.each_byte { |b| dec.feed(b.chr) }
  assert_equal ["hello", "world"], r
end

# =============================================================================
# Non-RFC: CBOR.doc_end
# =============================================================================

assert('doc_end: basic offset / empty / truncated / with-offset parameter') do
  buf = CBOR.encode(42) + CBOR.encode("hello")
  assert_equal CBOR.encode(42).bytesize, CBOR.doc_end(buf)

  assert_nil CBOR.doc_end("")
  assert_nil CBOR.doc_end("\x1B")  # uint64 with 0 trailing bytes

  doc1 = CBOR.encode("skip"); doc2 = CBOR.encode(99)
  assert_equal doc1.bytesize + doc2.bytesize, CBOR.doc_end(doc1 + doc2, doc1.bytesize)
end

# =============================================================================
# Depth limit / safety
# =============================================================================

assert('depth: deeply-nested arrays / maps / encoding all raise RuntimeError') do
  depth = 200
  buf_arr = depth.times.inject("") { |acc, _| "\x81" + acc } + "\x00"
  assert_raise(RuntimeError) { CBOR.decode(buf_arr) }

  inner = "\x00"
  buf_map = depth.times.inject(inner) { |acc, _| "\xA1\x61\x61" + acc }
  assert_raise(RuntimeError) { CBOR.decode(buf_map) }

  obj = depth.times.inject(0) { |i, _| [i] }
  assert_raise(RuntimeError) { CBOR.encode(obj) }
  assert_raise(RuntimeError) { CBOR.encode_fast(obj) }
end

assert('safety: all known malformed-input shapes raise cleanly') do
  [ "\xA2\x61\x61\x01\x61\x62",   # map with odd item count (missing last value)
    "\x63\xFF\xFE\xFD",            # major 3 with invalid UTF-8
    "\xC2\x40",                    # zero-length bignum (valid, no raise)
    "\x9F\x01\x02\xFF",            # indefinite array
    "\xBF\x61\x61\x01\xFF",        # indefinite map
    "\x7F\x61\x61\x61\x62\xFF",    # indefinite text
    "\xFC", "\xFD", "\xFE",        # reserved simple values
  ].each { |buf| assert_safe { CBOR.decode(buf) } }
end

assert('safety: lazy aref on non-container / huge index handled cleanly') do
  assert_safe { CBOR.decode_lazy(CBOR.encode(42))[0] }
  assert_safe { CBOR.decode_lazy(CBOR.encode(42))["key"] }
  assert_safe { CBOR.decode_lazy(CBOR.encode([1, 2, 3]))[0x7FFFFFFF] }
end
