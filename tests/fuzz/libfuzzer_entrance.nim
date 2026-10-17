## libFuzzer over one entrance of targets.nim, chosen by MCP_FUZZ_ENTRANCE.
## Built and run by libfuzzer_run.sh, which also gives libFuzzer the
## entrance's seeds, dictionary and length limit. The verdicts are those of
## the in-process runs: a reason, an exception or a Defect is a finding.

import std/os
import fuzz/libfuzzer   # foundation/nim-fuzz
import ./targets

let chosen = block:
  let name = getEnv("MCP_FUZZ_ENTRANCE")
  var found = -1
  for i, entrance in Entrances:
    if entrance.name == name: found = i
  if found < 0:
    var names = ""
    for entrance in Entrances: names.add " " & entrance.name
    quit("MCP_FUZZ_ENTRANCE must name an entrance:" & names, 2)
  found

proc target(input: string): string {.raises: [CatchableError].} =
  Entrances[chosen].target(input)

libFuzzerTarget(target)
