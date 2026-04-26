# Manual shuffle / pick helpers — mruby's Array#shuffle and Array#sample
# don't reliably accept a `random:` keyword argument across builds.
def shuffle_with(arr, rng)
  a = arr.dup
  i = a.length - 1
  while i > 0
    j = rng.rand(i + 1)
    a[i], a[j] = a[j], a[i]
    i -= 1
  end
  a
end

def pick(arr, rng)
  arr[rng.rand(arr.length)]
end

# Build a hash from a range — mruby's Range doesn't have #to_h with a block.
def build_hash(range)
  h = {}
  range.each { |i| k, v = yield i; h[k] = v }
  h
end

# -----------------------------------------------------------------------------
# Finding #3: lazy_resolve_tags pushes a CBOR::Lazy into sharedrefs;
# subsequent eager decode through decode_tag_sharedref returns the Lazy
# directly, leaking it into otherwise-eager output (type confusion).
# -----------------------------------------------------------------------------
assert('regression #3: eager materialization through sharedref returns plain Ruby value, not CBOR::Lazy') do
  shared = [10, 20, 30]
  obj = {
    "path_a" => { "ref" => shared },
    "path_b" => { "ref" => shared },
  }
  buf = CBOR.encode(obj, sharedrefs: true)

  lazy = CBOR.decode_lazy(buf)
  _ = lazy["path_a"]["ref"]
  result = lazy["path_b"]["ref"].value

  assert_false result.is_a?(CBOR::Lazy),
    "expected plain Ruby Array, got CBOR::Lazy (type confusion)"
  assert_equal [10, 20, 30], result
end

assert('randomized cache: identity preserved across access orders for nested structures') do
  shapes = [
    # flat array of 10 scalars
    -> { (0...10).to_a },

    # flat hash, 10 string keys
    -> { build_hash(0...10) { |i| ["k#{i}", i] } },

    # hash of hashes
    -> {
      build_hash(0...5) { |i|
        ["outer#{i}", build_hash(0...5) { |j| ["inner#{j}", i * 10 + j] }]
      }
    },

    # hash of arrays
    -> { build_hash(0...5) { |i| ["arr#{i}", (0...5).map { |j| i * 10 + j }] } },

    # array of hashes
    -> { (0...5).map { |i| build_hash(0...5) { |j| ["k#{j}", i * 10 + j] } } },

    # deep mixed: array of hashes containing arrays
    -> {
      (0...3).map { |i|
        { "id" => i,
          "items" => (0...3).map { |j| { "v" => i * 100 + j } } }
      }
    },
  ]

  rng = Random.new(42)

  shape_idx = 0
  shapes.each do |make|
    obj = make.call
    buf = CBOR.encode(obj)
    lazy = CBOR.decode_lazy(buf)

    # Enumerate every (path, expected_value) pair in the structure.
    paths = []
    walker = ->(node, prefix) {
      case node
      when Array
        node.each_with_index { |v, i| walker.call(v, prefix + [i]) }
      when Hash
        node.each { |k, v| walker.call(v, prefix + [k]) }
      else
        paths << [prefix, node]
      end
    }
    walker.call(obj, [])

    # Pass 1: random access via random method per path
    wrappers = {}
    shuffle_with(paths, rng).each do |entry|
      path, expected = entry
      method = pick([:aref, :dig], rng)
      wrapper = case method
                when :aref
                  path.inject(lazy) { |n, k| n[k] }
                when :dig
                  lazy.dig(*path)
                end
      wrappers[path] = wrapper
      assert_equal expected, wrapper.value,
        "shape #{shape_idx}, path #{path.inspect}: value mismatch on pass 1"
    end

    # Pass 2: random access again, must return SAME wrappers
    shuffle_with(paths, rng).each do |entry|
      path, expected = entry
      method = pick([:aref, :dig], rng)
      wrapper = case method
                when :aref
                  path.inject(lazy) { |n, k| n[k] }
                when :dig
                  lazy.dig(*path)
                end
      assert_same wrappers[path], wrapper,
        "shape #{shape_idx}, path #{path.inspect}: cache returned different wrapper"
      assert_equal expected, wrapper.value,
        "shape #{shape_idx}, path #{path.inspect}: value mismatch on pass 2"
    end

    shape_idx += 1
  end
end

assert('randomized cache: sharedref slot alignment under random access order') do
  rng = Random.new(1337)

  shared = [10, 20, 30]

  obj = {
    "a" => { "ref" => shared, "x" => 1 },
    "b" => { "ref" => shared, "x" => 2 },
    "c" => { "ref" => shared, "x" => 3 },
    "d" => { "nested" => { "ref" => shared } },
  }

  buf = CBOR.encode(obj, sharedrefs: true)

  10.times do |trial|
    lazy = CBOR.decode_lazy(buf)

    paths = [
      ["a", "ref"], ["b", "ref"], ["c", "ref"], ["d", "nested", "ref"],
      ["a", "x"],   ["b", "x"],   ["c", "x"],
    ]
    expected = {
      ["a", "ref"]           => shared,
      ["b", "ref"]           => shared,
      ["c", "ref"]           => shared,
      ["d", "nested", "ref"] => shared,
      ["a", "x"]             => 1,
      ["b", "x"]             => 2,
      ["c", "x"]             => 3,
    }

    shuffle_with(paths, rng).each do |path|
      method = pick([:aref, :dig], rng)
      val = case method
            when :aref then path.inject(lazy) { |n, k| n[k] }.value
            when :dig  then lazy.dig(*path).value
            end
      assert_equal expected[path], val,
        "trial #{trial}, path #{path.inspect}: got #{val.inspect}"
    end
  end
end

assert("lazy: identity preserved between root .value and per-leaf .value") do
  # Same Ruby objects appear in multiple places — the encoder will emit
  # Tag 28 once per object and Tag 29 references for subsequent occurrences.
  shared = "shared"
  doc  = [shared, shared, shared]

  bytes = CBOR.encode(doc, sharedrefs: true)
  lazy  = CBOR.decode_lazy(bytes)

  # 1. Materialize the entire tree from the root.
  full = lazy.value

  assert_same full[0], lazy[0].value

end