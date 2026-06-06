MRuby::Build.new do |conf|
    toolchain :gcc
    def for_windows?
        ('A'..'Z').to_a.any? { |vol| Dir.exist?("#{vol}:") }
    end
    unless for_windows?
        #conf.enable_sanitizer "address,undefined"
    end
    #conf.cxx.flags << '-fno-omit-frame-pointer' << '-g3' << '-ggdb3' << '-Og'
    #conf.cc.flags << '-fno-omit-frame-pointer' << '-g3' << '-ggdb3' << '-Og'
    #conf.enable_debug
    conf.cc.defines  << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
    conf.cxx.defines << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
    conf.enable_test
    conf.gembox 'default'
    conf.cc.flags << '-O3' << '-march=native' << '-g' << '-fno-omit-frame-pointer'
    conf.cxx.flags << '-O3' << '-march=native' << '-g' << '-fno-omit-frame-pointer'
    conf.gem File.expand_path(File.dirname(__FILE__))
end
