MRuby::Gem::Specification.new('mruby-cbor') do |spec|

  spec.license = 'Apache-2'
  spec.author  = 'Hendrik Beskow'
  spec.summary = 'simdjson for mruby'
  spec.add_dependency 'mruby-bigint'
  spec.add_dependency 'mruby-c-ext-helpers'
  spec.add_dependency 'mruby-time'
  spec.add_dependency 'mruby-string-is-utf8'
end
