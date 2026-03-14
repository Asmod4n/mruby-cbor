MRuby::Gem::Specification.new('mruby-cbor-fuzzer') do |spec|
  spec.license = 'Apache-2'
  spec.author  = 'Asmod4n'
  spec.summary = 'libFuzzer harness for mruby-cbor'

  spec.bins = %w[mruby-cbor-fuzzer]

  spec.add_dependency 'mruby-cbor'
  spec.add_dependency 'mruby-compiler'

  fuzz_flags = %w[-fsanitize=fuzzer]

  spec.cc.flags     << fuzz_flags
  spec.cxx.flags     << fuzz_flags
  spec.linker.flags << fuzz_flags

  # Instrument mruby-cbor's own C sources with fuzzer coverage
  spec.build.gems['mruby-cbor'].cc.flags << fuzz_flags
  spec.build.gems['mruby-cbor'].cxx.flags << fuzz_flags
  spec.build.gems['mruby-cbor'].linker.flags << fuzz_flags
end
