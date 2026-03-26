# ============================================================================
# Preferred float serialization (RFC 8949 §4.1)
#
# Each float is encoded in the smallest CBOR float width that represents
# the value losslessly: f16 (3 bytes) → f32 (5 bytes) → f64 (9 bytes).
#
# Width is determined by pure bit-pattern arithmetic, zero FP operations.
# NaN is always canonicalized to 0xF97E00 (quiet NaN) per RFC 8949 App. B.
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
  # 100.0 = 1.5625 * 2^6; f16 exp=21 (6+15), mant=0x240 (0.5625*1024)
  # h = (21<<10)|576 = 0x5640
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

# ── Width checks: values that must use f16 (3 bytes) ───────────────────────

assert('CBOR preferred float: f16-normal values encode as 3 bytes') do
  [0.0, -0.0, 1.0, 1.5, -1.5, 0.5, 0.25, 100.0, 65504.0,
   Float::INFINITY, -Float::INFINITY, Float::NAN].each do |v|
    assert_equal 3, CBOR.encode(v).bytesize, "expected f16 (3 bytes) for #{v}"
  end
end

assert('CBOR preferred float: f16 subnormal 2^-24 encodes as f16 (3 bytes)') do
  # 2^-24 is the smallest positive f16 subnormal (f16 0x0001).
  # Use integer arithmetic to guarantee the exact double value.
  v = 1.0 / 16777216.0   # 1.0 / 2^24 = 2^-24 exactly
  assert_equal 3, CBOR.encode(v).bytesize
  # Verify wire bytes: sign=0, exp16=0, mant16=1 → F9 00 01
  assert_equal "\xF9\x00\x01", CBOR.encode(v)
end

assert('CBOR preferred float: f16 subnormal 2^-23 encodes as f16 (3 bytes)') do
  v = 1.0 / 8388608.0   # 1.0 / 2^23 = 2^-23 exactly
  assert_equal 3, CBOR.encode(v).bytesize
  assert_equal "\xF9\x00\x02", CBOR.encode(v)
end

assert('CBOR preferred float: f16 subnormal 2^-15 (largest f16 sub) encodes as f16') do
  # 2^-15 = 512 * 2^-24; f16: exp16=0, mant16=0x200
  v = 1.0 / 32768.0   # 1.0 / 2^15 = 2^-15 exactly
  assert_equal 3, CBOR.encode(v).bytesize
  assert_equal "\xF9\x02\x00", CBOR.encode(v)
end

# ── Width checks: values that must use f32 (5 bytes) ───────────────────────

assert('CBOR preferred float: 65505.0 (above f16 normal max) encodes as f32 (5 bytes)') do
  assert_equal 5, CBOR.encode(65505.0).bytesize
end

assert('CBOR preferred float: 1.0e10 encodes as f32 (5 bytes)') do
  assert_equal 5, CBOR.encode(1.0e10).bytesize
end

assert('CBOR preferred float: f32 min normal (2^-126) encodes as f32 (5 bytes)') do
  # 2^-126: exact in f64 (exp64=897, mant64=0), fits in f32 range (exp32=1),
  # but exp32=1 is not in f16 range [103..142], so must be f32.
  v = 1.0 / 85070591730234615865843651857942052864.0  # 1/2^126
  # Simpler: build from shift. In mruby, 2.0**-126 if available, else:
  v2 = 0.5
  126.times { v2 = v2 * 0.5 }  # 0.5^127 = 2^-127... wrong
  # Actually use: start from 1.0 and halve 126 times
  v3 = 1.0; 126.times { v3 = v3 / 2.0 }
  assert_equal 5, CBOR.encode(v3).bytesize
end

# ── Width checks: values that must use f64 (9 bytes) ───────────────────────

assert('CBOR preferred float: 3.14 encodes as f64 (9 bytes)') do
  assert_equal 9, CBOR.encode(3.14).bytesize
end

assert('CBOR preferred float: 1.0/3.0 encodes as f64 (9 bytes)') do
  assert_equal 9, CBOR.encode(1.0/3.0).bytesize
end

assert('CBOR preferred float: 1.0e300 encodes as f64 (9 bytes)') do
  assert_equal 9, CBOR.encode(1.0e300).bytesize
end

# ── Round-trip correctness ──────────────────────────────────────────────────

assert('CBOR preferred float: all widths round-trip correctly') do
  # Build f16-subnormal test values without fragile literals
  sub_24 = 1.0 / 16777216.0   # 2^-24
  sub_23 = 1.0 / 8388608.0    # 2^-23
  sub_15 = 1.0 / 32768.0      # 2^-15

  values = [
    0.0, -0.0, 1.0, 1.5, -1.5, 0.5, 0.25, 100.0,
    65504.0, 65505.0, 1.0e10, 3.14, 1.0/3.0, 1.0e300,
    Float::INFINITY, -Float::INFINITY,
    sub_24, sub_23, sub_15,
  ]
  values.each do |v|
    decoded = CBOR.decode(CBOR.encode(v))
    assert_equal v, decoded, "round-trip failed for #{v}"
  end
  # NaN separately (NaN != NaN by IEEE)
  assert_true CBOR.decode(CBOR.encode(Float::NAN)).nan?
end

assert('CBOR preferred float: f16 subnormal powers of 2 round-trip') do
  # 2^-24 through 2^-15 inclusive: all must encode as f16 (3 bytes) and round-trip
  v = 1.0 / 16777216.0  # 2^-24
  10.times do |i|
    encoded = CBOR.encode(v)
    assert_equal 3, encoded.bytesize, "expected f16 for 2^#{-24+i}"
    assert_equal v, CBOR.decode(encoded), "round-trip failed for 2^#{-24+i}"
    v = v * 2.0
  end
end

# ── Lazy decode ─────────────────────────────────────────────────────────────

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

# ── In containers ───────────────────────────────────────────────────────────

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

# ── Interop: decode standard f16/f32 bytes from other implementations ───────

assert('CBOR preferred float: interop — decode f16 bytes for 1.0 (F9 3C 00)') do
  assert_equal 1.0, CBOR.decode("\xF9\x3C\x00")
end

assert('CBOR preferred float: interop — decode f16 bytes for 1.5 (F9 3E 00)') do
  assert_equal 1.5, CBOR.decode("\xF9\x3E\x00")
end

assert('CBOR preferred float: interop — decode f16 bytes for 100.0 (F9 56 40)') do
  assert_equal 100.0, CBOR.decode("\xF9\x56\x40")
end

assert('CBOR preferred float: interop — decode f32 bytes for 1.0') do
  assert_equal 1.0, CBOR.decode("\xFA\x3F\x80\x00\x00")
end

assert('CBOR preferred float: interop — decode f64 bytes for 1.0') do
  assert_equal 1.0, CBOR.decode("\xFB\x3F\xF0\x00\x00\x00\x00\x00\x00")
end

assert('CBOR preferred float: re-encode of decoded f32 uses preferred width') do
  # 1.0 decoded from f32 wire bytes must re-encode as f16
  decoded = CBOR.decode("\xFA\x3F\x80\x00\x00")
  assert_equal 1.0, decoded
  assert_equal 3, CBOR.encode(decoded).bytesize
end

assert('CBOR preferred float: re-encode of decoded f64 uses preferred width') do
  # 1.0 decoded from f64 wire bytes must re-encode as f16
  decoded = CBOR.decode("\xFB\x3F\xF0\x00\x00\x00\x00\x00\x00")
  assert_equal 1.0, decoded
  assert_equal 3, CBOR.encode(decoded).bytesize
end

assert('CBOR preferred float: f16 subnormal decoded from wire bytes round-trips') do
  # F9 00 01 = 2^-24 (f16 subnormal 0x0001)
  v = CBOR.decode("\xF9\x00\x01")
  assert_true v > 0.0
  # Re-encoding must give back F9 00 01
  assert_equal "\xF9\x00\x01", CBOR.encode(v)
end
