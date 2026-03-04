# ============================================================================
# Fuzz & exploit tests for CBOR decoder
# All tests must either succeed cleanly or raise RuntimeError/NotImplementedError.
# A crash, segfault or hang is a failure.
# ============================================================================

def assert_safe(&block)
  begin
    block.call
  rescue RuntimeError, NotImplementedError, TypeError, ArgumentError
    # expected - decoder rejected invalid input
  end
  assert_true true
end

# ============================================================================
# Random fuzzing
# ============================================================================

assert('CBOR fuzz: random bytes never crash') do
  r = Random.new(0xCB08)
  500.times do
    len  = r.rand(0..256)
    buf  = len.times.map { r.rand(0..255).chr }.join
    assert_safe { CBOR.decode(buf) }
    assert_safe { CBOR.decode_lazy(buf).value }
  end
end

assert('CBOR fuzz: single random bytes') do
  256.times do |b|
    assert_safe { CBOR.decode(b.chr) }
  end
end

assert('CBOR fuzz: valid prefix + random garbage appended') do
  valid = CBOR.encode({ "a" => [1, 2, 3], "b" => true })
  r = Random.new(42)
  100.times do
    tail = r.rand(1..64).times.map { r.rand(0..255).chr }.join
    # extra bytes after document - should raise or be ignored
    assert_safe { CBOR.decode(valid + tail) }
  end
end

assert('CBOR fuzz: truncated valid structures') do
  samples = [
    CBOR.encode([1, 2, 3, 4, 5]),
    CBOR.encode({ "hello" => "world", "n" => 42 }),
    CBOR.encode((1 << 200) + 99),
    CBOR.encode([true, false, nil, 1.5]),
  ]
  samples.each do |buf|
    buf.length.times do |cut|
      assert_safe { CBOR.decode(buf[0, cut]) }
    end
  end
end

assert('CBOR fuzz: bitflips in valid structures') do
  buf  = CBOR.encode({ "statuses" => (1..10).map { |i| { "id" => i } } })
  r    = Random.new(7)
  200.times do
    pos     = r.rand(0...buf.length)
    flipped = buf.dup
    flipped.setbyte(pos, r.rand(0..255))
    assert_safe { CBOR.decode(flipped) }
    assert_safe { CBOR.decode_lazy(flipped).value }
  end
end

assert('CBOR fuzz: empty string') do
  assert_safe { CBOR.decode("") }
end

assert('CBOR fuzz: all-zero buffer') do
  [1, 2, 4, 8, 16, 64, 256].each do |len|
    assert_safe { CBOR.decode("\x00" * len) }
  end
end

assert('CBOR fuzz: all-0xFF buffer') do
  [1, 2, 4, 8, 16, 64].each do |len|
    assert_safe { CBOR.decode("\xFF" * len) }
  end
end

# ============================================================================
# Handcrafted exploits
# ============================================================================

assert('CBOR exploit: array length claims 0xFFFFFFFF items') do
  # major 4, 4-byte length = 0xFFFFFFFF, then EOF
  buf = "\x9A\xFF\xFF\xFF\xFF"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: map length claims 0xFFFFFFFF pairs') do
  # major 5, 4-byte length = 0xFFFFFFFF, then EOF
  buf = "\xBA\xFF\xFF\xFF\xFF"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: byte string length claims 0xFFFFFFFF bytes') do
  # major 2, 4-byte length = 0xFFFFFFFF, then EOF
  buf = "\x5A\xFF\xFF\xFF\xFF"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: text string length claims 0xFFFFFFFF bytes') do
  # major 3, 4-byte length = 0xFFFFFFFF, then EOF
  buf = "\x7A\xFF\xFF\xFF\xFF"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: 8-byte length = 0xFFFFFFFFFFFFFFFF') do
  # array with uint64 max item count
  buf = "\x9B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: deeply nested arrays (stack overflow attempt)') do
  # 10000 nested arrays: [[[...[] ]]]
  depth = 10_000
  buf   = "\x81" * depth + "\x00"
  assert_safe { CBOR.decode(buf) }
  assert_safe { CBOR.decode_lazy(buf).value }
end

assert('CBOR exploit: deeply nested maps') do
  # {"a": {"a": {"a": ...}}}
  depth = 5_000
  buf   = ("\xA1\x61\x61" * depth) + "\x00"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: truncated float16 (1 byte)') do
  buf = "\xF9\x3C"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: truncated float32 (3 bytes)') do
  buf = "\xFA\x3F\x80\x00"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: truncated float64 (7 bytes)') do
  buf = "\xFB\x3F\xF0\x00\x00\x00\x00\x00"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: tag with no following item') do
  buf = "\xC0"  # tag(0), then EOF
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: tag 2 (bignum) with non-bytes payload') do
  # Tag 2 followed by integer instead of byte string
  buf = "\xC2\x05"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: tag 3 (neg bignum) with truncated bytes') do
  # Tag 3, byte string len=10, only 3 bytes follow
  buf = "\xC3\x4A\x01\x02\x03"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: tag 29 with no prior tag 28 (eager)') do
  buf = "\xD8\x1D\x00"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: tag 29 before tag 28 in array') do
  # [Tag29(0), Tag28(42)] - ref before shareable is registered
  buf = "\x82\xD8\x1D\x00\xD8\x1C\x18\x2A"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: tag 28 wrapping tag 28') do
  # Tag28(Tag28(42))
  buf = "\xD8\x1C\xD8\x1C\x18\x2A"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: tag 29 index overflow (uint64 max)') do
  # Tag29, uint64 = 0xFFFFFFFFFFFFFFFF
  buf = "\xD8\x1D\x1B\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: map with odd item count (missing last value)') do
  # map of 2 pairs but only 3 items encoded
  buf = "\xA2\x61\x61\x01\x61\x62"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: text string with invalid UTF-8') do
  # major 3, len=3, bytes are not valid UTF-8
  buf = "\x63\xFF\xFE\xFD"
  assert_safe { CBOR.decode(buf) }
end

assert('CBOR exploit: reserved simple values (info 28, 29, 30)') do
  ["\xFC", "\xFD", "\xFE"].each do |buf|
    assert_safe { CBOR.decode(buf) }
  end
end

assert('CBOR exploit: indefinite-length array marker') do
  # 0x9F = indefinite array begin
  assert_safe { CBOR.decode("\x9F\x01\x02\xFF") }
end

assert('CBOR exploit: indefinite-length map marker') do
  assert_safe { CBOR.decode("\xBF\x61\x61\x01\xFF") }
end

assert('CBOR exploit: indefinite-length text string') do
  assert_safe { CBOR.decode("\x7F\x61\x61\x61\x62\xFF") }
end

assert('CBOR exploit: lazy aref on non-container') do
  # decode integer lazily, then try to index it
  buf  = CBOR.encode(42)
  lazy = CBOR.decode_lazy(buf)
  assert_safe { lazy[0] }
  assert_safe { lazy["key"] }
end

assert('CBOR exploit: lazy aref with huge array index') do
  buf  = CBOR.encode([1, 2, 3])
  lazy = CBOR.decode_lazy(buf)
  assert_safe { lazy[0x7FFFFFFF] }
end

assert('CBOR exploit: zero-length bignum tag') do
  # Tag 2, byte string of length 0
  buf = "\xC2\x40"
  assert_safe { CBOR.decode(buf) }
end
