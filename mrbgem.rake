MRuby::Gem::Specification.new('mruby-cbor') do |spec|

  spec.license = 'Apache-2'
  spec.author  = 'Hendrik Beskow'
  spec.summary = 'CBOR implementation for mruby'
  spec.add_dependency 'mruby-c-ext-helpers'
  spec.add_dependency 'mruby-time'
  spec.add_dependency 'mruby-string-is-utf8'
  spec.add_dependency 'mruby-native-ext-type', github: 'Asmod4n/mruby-native-ext-type', branch: 'main'
  spec.add_test_dependency 'mruby-bigint'
  spec.add_test_dependency 'mruby-random'
  spec.add_test_dependency 'mruby-io'
  spec.add_test_dependency 'mruby-b64'
  spec.add_test_dependency 'mruby-fast-json'
end
