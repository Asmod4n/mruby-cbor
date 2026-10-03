# Alternates the builds given as arguments, 11 rounds, as uid 1000.
id -u; ps -u $(id -u) -o pid,ni,comm
for r in $(seq 11); do
  for a in "$@"; do
    /cb/build-$a/host/bin/mruby /cb/bench.rb /cb 2>&1 | sed "s/^/$a /"
  done
done
