require_relative 'mrblib/version'

MRuby::Gem::Specification.new('mruby-cbor') do |spec|

  spec.license = 'Apache-2'
  spec.author  = 'Hendrik Beskow'
  spec.summary = 'CBOR implementation for mruby'
  spec.version = CBOR::VERSION
  spec.add_dependency 'mruby-c-ext-helpers'
  spec.add_dependency 'mruby-string-is-utf8'
  spec.add_dependency 'mruby-native-ext-type', github: 'Asmod4n/mruby-native-ext-type', branch: 'main'
  spec.add_dependency 'mruby-str-constantize', github: 'Asmod4n/mruby-str-constantize', branch: 'main'
  # The preprocessor cannot test for a name, so the header is read here:
  # mruby renamed mrb_bint_from_bytes to mrb_bint_new_bytes and
  # mrb_bint_size to mrb_bint_bytes_size on 2026-09-06 (mruby/mruby
  # 053056f). src/mrb_cbor.c takes either name behind this define.
  internal_h = "#{build.root}/include/mruby/internal.h"
  if File.exist?(internal_h) && File.read(internal_h).include?('mrb_bint_new_bytes')
    spec.cc.defines << 'MRB_CBOR_BINT_NEW_BYTES'
  end

  spec.add_test_dependency 'mruby-bigint'
  spec.add_test_dependency 'mruby-random'
  spec.add_test_dependency 'mruby-io'
  spec.add_test_dependency 'mruby-b64'
  spec.add_test_dependency 'mruby-metaprog'
  spec.add_test_dependency 'mruby-sprintf'
  spec.add_test_dependency 'mruby-string-ext'
  spec.add_test_dependency 'mruby-fast-json'
end
