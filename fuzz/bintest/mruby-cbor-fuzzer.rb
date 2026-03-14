require 'open3'
require 'fileutils'

GEM_ROOT   = File.expand_path('../', __dir__)
CORPUS_DIR = File.join(GEM_ROOT, 'corpus')
DICT_FILE  = File.join(GEM_ROOT, 'cbor.dict')

assert('mruby-cbor-fuzzer: no crashes in fuzzing run') do
  findings_dir = File.join(GEM_ROOT, 'findings')
  FileUtils.mkdir_p(findings_dir)

  cmd = cmd_list('mruby-cbor-fuzzer') + [
    CORPUS_DIR,
    "-dict=#{DICT_FILE}",
    "-jobs=7",
    "-artifact_prefix=#{findings_dir}/",
    "-max_len=4096",
     "-ignore_ooms=0"
  ]

  Dir.chdir(findings_dir) do
    pid = Process.spawn(*cmd, out: '/dev/null', err: '/dev/null')
    Process.detach(pid)

    # Kill fuzzer on Ctrl+C
    trap('INT') do
      puts "\nKilling fuzzer..."
      Process.kill(9, pid)
      exit(1)
    end
  end

  sleep 0.1 until (0..6).all? { |n| File.exist?(File.join(findings_dir, "fuzz-#{n}.log")) }

  threads = (0..6).map do |n|
    log = File.join(findings_dir, "fuzz-#{n}.log")
    Thread.new do
      File.open(log) do |f|
        loop do
          line = f.gets
          line ? $stderr.print("[#{n}] #{line}") : sleep(0.05)
          GC.start
        end
      end
    end
  end

  loop do
    done = (0..6).count do |n|
      log = File.join(findings_dir, "fuzz-#{n}.log")
      File.exist?(log) && File.read(log) =~ /Done \d+|SUMMARY:/
    end
    break if done == 16
    sleep 5
  end

  threads.each(&:kill)

  crashes = (0..6).select do |n|
    log = File.join(findings_dir, "fuzz-#{n}.log")
    File.exist?(log) && File.read(log).include?('SUMMARY:')
  end

  assert_true crashes.empty?,
    "crashes in workers: #{crashes.map { |n| "fuzz-#{n}.log" }.join(', ')}"
end
