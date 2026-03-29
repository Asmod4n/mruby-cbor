MRuby::Build.new do |conf|
  conf.toolchain :clang

  conf.enable_sanitizer "address,undefined"

  conf.enable_debug
  conf.enable_bintest
  conf.cc.defines  << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
  conf.cxx.defines << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
  conf.gem '../'
  conf.gem File.expand_path(__dir__)
end
