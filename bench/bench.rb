# One run of every public method of mruby-cbor on every document.
# ARGV[0]: the directory with twitter.cbor. Each line: name doc us_per_op.
# Every operation reads a new copy of its document, from enough copies
# that they do not fit the L3, so every document is cold.

class BenchPoint
  native_ext_type :@x, Integer
  native_ext_type :@y, Integer
  def initialize(x = 0, y = 0); @x = x; @y = y; end
end
CBOR.register_tag(1000, BenchPoint)

def make_docs(dir)
  r = 12345
  rnd = lambda { r = (r * 1103515245 + 12345) & 0x7fffffff; r }
  ints    = Array.new(10_000) { rnd.call - 0x3fffffff }
  floats  = Array.new(10_000) { rnd.call / 7.0 }
  strings = Array.new(5_000) { "s" * (rnd.call % 40) }
  records = Array.new(2_000) do |i|
    { "id" => i, "name" => "car #{i}", "price" => rnd.call / 100.0,
      "tags" => ["a", "b", "c"], "owner" => { "first" => "x", "age" => rnd.call % 90 } }
  end
  nested = 0.upto(28).inject(1) { |acc, _| [acc] }
  shared_leaf = { "k" => "v" * 20 }
  shared = Array.new(2_000) { shared_leaf }
  points = Array.new(2_000) { |i| BenchPoint.new(i, -i) }
  twitter = File.open("#{dir}/twitter.cbor", "rb") { |f| f.read }
  {
    "ints" => [ints, CBOR.encode(ints)],
    "floats" => [floats, CBOR.encode(floats)],
    "strings" => [strings, CBOR.encode(strings)],
    "records" => [records, CBOR.encode(records)],
    "nested" => [nested, CBOR.encode(nested)],
    "shared" => [shared, CBOR.encode(shared, sharedrefs: true)],
    "points" => [points, CBOR.encode(points)],
    "twitter" => [CBOR.decode(twitter), twitter],
  }
end

L3 = 300 * 1024 * 1024
def copies_of(bytes)
  n = [L3 / [bytes.bytesize, 1].max + 1, 2000].min
  n = 8 if n < 8
  Array.new(n) { bytes.dup }
end

def measure(name, doc, copies, &op)
  ops = [copies.size, 400].min
  ops = 8 if ops < 8
  t = Time.now
  i = 0
  while i < ops
    op.call(copies[i % copies.size])
    i += 1
  end
  puts "#{name} #{doc} #{((Time.now - t) * 1e6 / ops).round(2)}"
end

docs = make_docs(ARGV[0] || ".")
paths = { "twitter" => CBOR::Path.compile("$.statuses[*].user.screen_name"),
          "records" => CBOR::Path.compile("$[*].owner.age") }

docs.each do |doc, (value, bytes)|
  copies = copies_of(bytes)
  values = Array.new([copies.size, 64].min) { CBOR.decode(bytes) }
  shared = doc == "shared"
  measure("encode", doc, values) { |v| CBOR.encode(v, sharedrefs: shared) }
  measure("decode", doc, copies) { |b| CBOR.decode(b) }
  measure("doc_end", doc, copies) { |b| CBOR.doc_end(b) }
  measure("lazy_value", doc, copies) { |b| CBOR.decode_lazy(b).value }
  measure("lazy_first", doc, copies) do |b|
    l = CBOR.decode_lazy(b)
    value.is_a?(Hash) ? l[value.keys.first] : l[0]
  end
  measure("lazy_last", doc, copies) do |b|
    l = CBOR.decode_lazy(b)
    value.is_a?(Hash) ? l[value.keys.last] : l[-1]
  end
  if (p = paths[doc])
    measure("path_at", doc, copies) { |b| p.at(CBOR.decode_lazy(b)) }
  end
  if doc == "twitter"
    measure("dig", doc, copies) { |b| CBOR.decode_lazy(b).dig("statuses", 3, "user", "screen_name") }
  end
  stream_bytes = bytes * 4
  scopies = copies_of(stream_bytes)
  measure("stream", doc, scopies) { |b| n = 0; CBOR.stream(b) { |_| n += 1 } }
end
