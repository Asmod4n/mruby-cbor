assert('passes the official test vectors') do
  data = File.read(File.expand_path("../../test-vectors/appendix_a.json", __FILE__))

  # Vectors that cannot roundtrip in mruby by design:
  #
  # - Simple values other than false/true/null (f0, f7, f820, f8ff):
  #   mruby decodes all of these as nil, so re-encoding produces f6.
  #
  # - Unhandled tags (tag 0, 1, 23, 24, 32):
  #   mruby decodes these as CBOR::UnhandledTag objects. Without a registered
  #   encoder for those tags, re-encoding produces the object's string repr.
  #
  # - Byte strings (40, 4401020304):
  #   mruby has no separate byte-string type; decoded bytes are Ruby Strings.
  #   When the bytes happen to be valid UTF-8 they re-encode as text (major 3).
  #
  ROUNDTRIP_SKIP = %w[
    f7 f0 f820 f8ff
    c074323031332d30332d32315432303a30343a30305a
    c11a514b67b0
    c1fb41d452d9ec200000
    d74401020304
    d818456449455446
    d82076687474703a2f2f7777772e6578616d706c652e636f6d
    40
    4401020304
  ].freeze

  tests = JSON.parse_lazy(data)
  tests.array_each do |test|
    hex       = test["hex"]
    roundtrip = test["roundtrip"]

    begin
      wire    = B64.decode(test["cbor"])
      decoded = CBOR.decode(wire)

      # Value check
      if test["decoded"]
        assert_equal test["decoded"], decoded
      end

      # Roundtrip check: re-encoding a canonical-encoded value must reproduce
      # the original wire bytes exactly.
      if roundtrip && !ROUNDTRIP_SKIP.include?(hex)
        reencoded = CBOR.encode(decoded)
        assert_equal wire, reencoded,
          "roundtrip failed for #{hex}: got #{reencoded.bytes.map{|b| '%02x'%b}.join}"
      end

    rescue NotImplementedError
      # indefinite-length items not supported — skip gracefully
    end
  end
end
