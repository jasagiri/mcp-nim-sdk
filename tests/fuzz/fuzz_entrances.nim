## A fuzzing run over the places that read a peer's text. Not part of the
## tests: it runs for minutes, and it needs the fuzzer of ../nim-fuzz-inprocess, which
## is beside this repository and not a dependency of it. From the root:
##
##   nim c -r --cc:clang -d:fuzzCoverage --panics:off --path:../nim-fuzz-inprocess/src \
##     --nimcache:build/nimcache/fuzz -o:build/fuzz_entrances \
##     tests/fuzz/fuzz_entrances.nim [runs per target] [target ...]
##
## A finding is printed and saved under tests/fuzz/corpus/<target>/, where
## `tests/internal/test_fuzz_regressions.nim` runs it from then on. Exits 1 if
## anything was found.

import std/[os, strutils]
import nim_fuzz_inprocess
import ./targets

let runs = if paramCount() >= 1: parseInt(paramStr(1)) else: 200_000
var wanted: seq[string]
for i in 2 .. paramCount(): wanted.add paramStr(i)
let corpus = currentSourcePath().parentDir / "corpus"
var found = 0
for entrance in Entrances:
  if wanted.len > 0 and entrance.name notin wanted: continue
  let report = fuzz(FuzzTarget(entrance.target), entrance.seeds,
    FuzzConfig(runs: runs, seed: 0, maxLen: entrance.maxLen, dictionary: entrance.words,
               slowAfterMs: 500, inFlightPath: getTempDir() / "mcp_nim_sdk_fuzz_in_flight"))
  echo entrance.name, ": ", report.runs, " inputs, ", report.corpusSize, " kept, ", report.edges,
       " edges, ", report.findings.len, " findings",
       (if report.coverageGuided: "" else: " (no coverage signal)")
  for finding in report.findings:
    inc found
    echo "  ", finding.kind, " | ", finding.reason, " | ", finding.input.escape
    echo "  saved: ", saveInput(corpus / entrance.name, finding.input)
quit(if found == 0: 0 else: 1)
