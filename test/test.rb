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
  assert_raise(RuntimeError) { CBOR.decode(broken) }
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
  assert_nil lazy["missing"]
end

assert('CBOR::Lazy array out of bounds') do
  ary = [1,2,3]
  lazy = CBOR.decode_lazy(CBOR.encode(ary))
  assert_nil lazy[99]
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
