#!/bin/sh
# Long fuzzing with libFuzzer and AddressSanitizer over the entrances of
# targets.nim (the release ledger's INP-04). From the repository root:
#
#   sh tests/fuzz/libfuzzer_run.sh SECONDS NAME... [-- SECONDS NAME...]
#
# Needs nim-fuzz-inprocess with fuzz/libfuzzer ($NIM_FUZZ, else ../nim-fuzz-inprocess) and a clang with the libFuzzer
# runtime: $LLVM_CLANG, else Homebrew's LLVM. Each entrance's log, the inputs
# libFuzzer kept and any crashing input are under build/libfuzzer/<name>/.
# A finding found here is saved under tests/fuzz/corpus/<name>/ by hand, after
# it is understood, so that test_fuzz_regressions replays it from then on.
set -eu
clang=${LLVM_CLANG:-/opt/homebrew/opt/llvm/bin/clang}
nimfuzz=${NIM_FUZZ:-../nim-fuzz-inprocess}
out=build/libfuzzer
mkdir -p "$out"
nim c --hints:off --path:"$nimfuzz/src" --nimcache:build/nimcache/export \
  -o:"$out/export_entrances" tests/fuzz/export_entrances.nim
"$out/export_entrances" "$out" > /dev/null
nim c --hints:off --warnings:off --cc:clang --clang.exe:"$clang" --clang.linkerexe:"$clang" \
  --noMain --panics:on -d:useMalloc -d:noSignalHandler \
  --passC:-fsanitize=fuzzer,address --passL:-fsanitize=fuzzer,address \
  --path:"$nimfuzz/src" --nimcache:build/nimcache/libfuzzer \
  -o:"$out/libfuzzer_entrance" tests/fuzz/libfuzzer_entrance.nim
seconds=$1; shift
status=0
for name in "$@"; do
  if [ "$name" = "--" ]; then continue; fi
  case "$name" in [0-9]*) seconds=$name; continue ;; esac
  dir="$out/$name"
  mkdir -p "$dir/corpus"
  echo "== $name: $seconds s"
  # stdio's transport logs every line that is not JSON to stderr; its finding
  # reasons are read by replaying the saved input instead.
  mask=0
  [ "$name" = stdioLines ] && mask=2
  if ! MCP_FUZZ_ENTRANCE=$name "$out/libfuzzer_entrance" "$dir/corpus" "$dir/seeds" \
      -max_total_time="$seconds" -max_len="$(cat "$dir/max_len")" -dict="$dir/dict" \
      -timeout=10 -rss_limit_mb=4096 -close_fd_mask=$mask -print_final_stats=1 \
      -artifact_prefix="$dir/" > "$dir/log" 2>&1; then
    status=1
    echo "   finding: see $dir/log"
  fi
  grep -E "^stat::(number_of_executed_units|average_exec_per_sec|peak_rss_mb)|cov: [0-9]+ ft" "$dir/log" | tail -4
done
exit $status
