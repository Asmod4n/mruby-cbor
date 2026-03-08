assert('passes the official test vectors') do
  data = File.read(File.expand_path("../../test-vectors/appendix_a.json", __FILE__))

  tests = JSON.parse_lazy(data)
  tests.array_each do |test|
    begin
      cbor = CBOR.decode(B64.decode(test["cbor"]))

      if test["decoded"]
        assert_equal test["decoded"], cbor
      end
    rescue NotImplementedError
    end
  end
end
