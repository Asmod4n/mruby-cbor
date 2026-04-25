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
    "-jobs=3",
    "-artifact_prefix=#{findings_dir}/",
    "-max_len=65536",
     "-ignore_ooms=1",
     "-use_value_profile=1",
     "-rss_limit_mb=5000"
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

  sleep 2
  actual_workers = Dir[File.join(findings_dir, 'fuzz-*.log')].map { |f|
    File.basename(f)[/\d+/].to_i
  }.sort

  $stderr.puts "Detected #{actual_workers.size} workers: #{actual_workers.inspect}"

  sleep 0.1 until actual_workers.all? { |n| File.exist?(File.join(findings_dir, "fuzz-#{n}.log")) }

  threads = actual_workers.map do |n|
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
    done = actual_workers.count do |n|
      log = File.join(findings_dir, "fuzz-#{n}.log")
      File.exist?(log) && File.read(log) =~ /Done \d+|SUMMARY:/
    end
    break if done == actual_workers.size
    sleep 5
  end

  threads.each(&:kill)

  crashes = actual_workers.select do |n|
    log = File.join(findings_dir, "fuzz-#{n}.log")
    File.exist?(log) && File.read(log).include?('SUMMARY:')
  end

  assert_true crashes.empty?,
    "crashes in workers: #{crashes.map { |n| "fuzz-#{n}.log" }.join(', ')}"
end
