MRuby::Build.new do |conf|
  toolchain :gcc
  conf.cc.defines << 'MRB_HIGH_PROFILE'
  conf.cxx.defines << 'MRB_HIGH_PROFILE'
  conf.gembox 'default'
  conf.cc.flags << '-O2' << '-march=x86-64-v4' << '-falign-functions=64' << '-falign-loops=64'
  conf.cxx.flags << '-O2' << '-march=x86-64-v4' << '-falign-functions=64' << '-falign-loops=64'
  conf.gem '/cbor'
end
