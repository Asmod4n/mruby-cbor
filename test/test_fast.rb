# ============================================================================
# CBOR.encode_fast / CBOR.decode_fast
#
# Fast path: fixed-width integers/floats, canonical lengths, no tags,
# no sharedrefs, no UTF-8 validation, no bigints.
# Only valid between mruby binaries compiled with identical build config.
# ============================================================================

# ── Primitives ───────────────────────────────────────────────────────────────

assert('CBOR fast: integer roundtrip') do
  assert_equal 0,    CBOR.decode_fast(CBOR.encode_fast(0))
  assert_equal 1,    CBOR.decode_fast(CBOR.encode_fast(1))
  assert_equal 127,  CBOR.decode_fast(CBOR.encode_fast(127))
  assert_equal 255,  CBOR.decode_fast(CBOR.encode_fast(255))
  assert_equal 256,  CBOR.decode_fast(CBOR.encode_fast(256))
  assert_equal 65535, CBOR.decode_fast(CBOR.encode_fast(65535))
  assert_equal 65536, CBOR.decode_fast(CBOR.encode_fast(65536))
end

assert('CBOR fast: negative integer roundtrip') do
  assert_equal(-1,    CBOR.decode_fast(CBOR.encode_fast(-1)))
  assert_equal(-42,   CBOR.decode_fast(CBOR.encode_fast(-42)))
  assert_equal(-1000, CBOR.decode_fast(CBOR.encode_fast(-1000)))
  assert_equal(-65536, CBOR.decode_fast(CBOR.encode_fast(-65536)))
end

assert('CBOR fast: integer MRB_INT_MAX roundtrip') do
  n = 2**30 - 1
  assert_equal n, CBOR.decode_fast(CBOR.encode_fast(n))
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

assert('CBOR fast: boolean and nil roundtrip') do
  assert_equal true,  CBOR.decode_fast(CBOR.encode_fast(true))
  assert_equal false, CBOR.decode_fast(CBOR.encode_fast(false))
  assert_nil          CBOR.decode_fast(CBOR.encode_fast(nil))
end

assert('CBOR fast: string roundtrip') do
  assert_equal "",      CBOR.decode_fast(CBOR.encode_fast(""))
  assert_equal "hello", CBOR.decode_fast(CBOR.encode_fast("hello"))
  assert_equal "hällo", CBOR.decode_fast(CBOR.encode_fast("hällo"))
end

# ── Containers ───────────────────────────────────────────────────────────────

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

assert('CBOR fast: mixed negative and positive integers') do
  ary = [-100, -1, 0, 1, 100, -65536, 65536]
  assert_equal ary, CBOR.decode_fast(CBOR.encode_fast(ary))
end

# ── Wire format properties ────────────────────────────────────────────────────

assert('CBOR fast: integers use fixed width') do
  # small integer 1 encodes as fixed-width in fast, 1 byte in canonical
  fast_size = CBOR.encode_fast(1).bytesize
  canon_size = CBOR.encode(1).bytesize
  assert_true fast_size >= canon_size
end

assert('CBOR fast: string lengths use canonical shortest form') do
  # a 5-char string should have a 1-byte length prefix in both
  fast  = CBOR.encode_fast("hello")
  canon = CBOR.encode("hello")
  # both: 1 byte header + 5 bytes content = 6 bytes
  assert_equal canon.bytesize, fast.bytesize
end

assert('CBOR fast: array count uses canonical shortest form') do
  # a 3-element array of booleans: count fits in 1 byte in both
  fast  = CBOR.encode_fast([true, false, nil])
  canon = CBOR.encode([true, false, nil])
  # container overhead should be identical — only scalar widths differ
  # (true/false/nil are 1 byte each in both paths)
  assert_equal canon.bytesize, fast.bytesize
end

# ── Unsupported types raise ───────────────────────────────────────────────────

assert('CBOR fast: symbol always encodes as tag 39 + string') do
  buf = CBOR.encode_fast(:hello)
  assert_equal :hello, CBOR.decode_fast(buf)
end

assert('CBOR fast: symbol in map') do
  h = { hello: 1, world: 2 }
  assert_equal h, CBOR.decode_fast(CBOR.encode_fast(h))
end

assert('CBOR fast: class roundtrip') do
  assert_equal String,   CBOR.decode_fast(CBOR.encode_fast(String))
  assert_equal Integer,  CBOR.decode_fast(CBOR.encode_fast(Integer))
  assert_equal ArgumentError, CBOR.decode_fast(CBOR.encode_fast(ArgumentError))
end

assert('CBOR fast: class in structure') do
  h = { "klass" => StandardError, "msg" => "oops" }
  assert_equal h, CBOR.decode_fast(CBOR.encode_fast(h))
end

assert('CBOR fast: decode canonical buffer raises') do
  # canonical small integer 1 = 0x01 (info < 24, not fixed-width)
  # fast decoder expects fixed-width info byte — should raise
  assert_raise(RuntimeError) { CBOR.decode_fast(CBOR.encode(1)) }
end

# ── Fuzz safety ───────────────────────────────────────────────────────────────

assert('CBOR fast: random bytes never crash') do
  r = Random.new(0xFA57)
  200.times do
    len = r.rand(0..128)
    buf = len.times.map { r.rand(0..255).chr }.join
    begin
      CBOR.decode_fast(buf)
    rescue RuntimeError, RangeError, TypeError, NotImplementedError, ArgumentError, NameError
      # expected — bad input rejected cleanly
    end
  end
  assert_true true
end

assert('CBOR fast: truncated buffers never crash') do
  samples = [
    CBOR.encode_fast([1, 2, 3]),
    CBOR.encode_fast({ "a" => 1, "b" => 2 }),
    CBOR.encode_fast(42),
    CBOR.encode_fast("hello"),
  ]
  samples.each do |buf|
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

# ── Registered tags fall back to canonical ────────────────────────────────────

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

  p = FastPoint.new(3, 7)
  buf = CBOR.encode_fast(p)
  # falls back to canonical — must be decodable by canonical decoder
  decoded = CBOR.decode_fast(buf)
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

  ary = [1, FastBox.new(42), "hello", FastBox.new(99)]
  buf = CBOR.encode_fast(ary)
  # integers and string are fast-encoded, FastBox falls back to canonical
  # canonical decoder handles the mixed buffer correctly
  decoded = CBOR.decode_fast(buf)
  assert_equal 42, decoded[1].instance_variable_get(:@val)
  assert_equal "hello", decoded[2]
  assert_equal 99, decoded[3].instance_variable_get(:@val)
end

assert('CBOR fast: decode_fast on fully-fast buffer with registered tag fallback') do
  class FastThing
    native_ext_type :@n, Integer
    def initialize(n = 0); @n = n; end
  end
  CBOR.register_tag(9003, FastThing)

  t = FastThing.new(55)
  # encode_fast falls back to canonical for registered tags —
  # the resulting buffer is valid canonical CBOR, so canonical decode works
  buf = CBOR.encode_fast(t)
  assert_equal buf, CBOR.encode(t)  # fallback produces identical output
  decoded = CBOR.decode_fast(buf)
  assert_true decoded.is_a?(FastThing)
  assert_equal 55, decoded.instance_variable_get(:@n)
end

# ── Full registered tag API through fast path ─────────────────────────────────
#
# encode_fast falls back to encode_value for registered types, so the full
# registered tag API — hooks, type checking, allowlist, proc tags — all work
# exactly as in the canonical path. The output is valid canonical CBOR.

assert('CBOR fast: _before_encode hook fires on fallback') do
  class FastItem
    attr_accessor :value
    native_ext_type :@value, Integer
    def initialize(v); @value = v; end
    def _before_encode; @value = @value * 2; self; end
  end
  CBOR.register_tag(9010, FastItem)

  item = FastItem.new(5)
  buf  = CBOR.encode_fast(item)
  decoded = CBOR.decode_fast(buf)
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

  cfg     = FastConfig.new(30)
  buf     = CBOR.encode_fast(cfg)
  decoded = CBOR.decode_fast(buf)
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

  r = FastRecord.new
  r.id   = 7
  r.name = "alice"
  buf = CBOR.encode_fast(r)

  # inject extra fields by crafting payload manually and wrapping with tag
  payload = { "id" => 7, "name" => "alice", "secret" => "ignored" }
  tagged  = "\xD9\x23\x34" + CBOR.encode_fast(payload)  # tag(9012, payload)
  decoded = CBOR.decode_fast(tagged)
  assert_true decoded.is_a?(FastRecord)
  assert_equal 7,       decoded.id
  assert_equal "alice", decoded.name
  assert_equal 2, decoded.instance_variables.length
end

assert('CBOR fast: registered tag inside nested structure') do
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

  buf     = CBOR.encode_fast(obj)
  decoded = CBOR.decode_fast(buf)

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
  # falls back to canonical proc-tag encode
  assert_equal buf, CBOR.encode(w)
  decoded = CBOR.decode_fast(buf)
  assert_true decoded.is_a?(FastWrapper)
  assert_equal 21, decoded.val
end

assert('CBOR fast: fallback output identical to canonical for registered types') do
  class FastShape
    native_ext_type :@sides, Integer
    native_ext_type :@color, String
    def initialize(s = 0, c = ""); @sides = s; @color = c; end
  end
  CBOR.register_tag(9015, FastShape)

  obj = FastShape.new(4, "red")
  assert_equal CBOR.encode(obj), CBOR.encode_fast(obj)
end
