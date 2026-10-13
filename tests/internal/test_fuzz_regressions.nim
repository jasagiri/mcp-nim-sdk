## The seeds of every fuzzing target, and the inputs fuzzing found, run with
## the other tests.
##
## Each file under tests/fuzz/corpus/<target>/ is an input that once made the
## library do something wrong. They are handled now, and stay so. The fuzzing
## itself is not a test: see tests/fuzz/fuzz_entrances.nim.

import std/[unittest, os, algorithm, strutils]
import ../fuzz/targets

const Corpus = currentSourcePath().parentDir.parentDir / "fuzz" / "corpus"

proc found(name: string): seq[string] =
  ## The inputs kept for a target, in the order of their file names.
  var files: seq[string]
  for file in walkFiles(Corpus / name / "*.input"):
    files.add file
  files.sort()
  for file in files:
    result.add readFile(file)

proc wrong(entrance: Entrance, input: string): string =
  ## What a target says of an input; a defect and an error the target does
  ## not expect are said too, where a fuzzer would have recorded them.
  try:
    entrance.target(input)
  except CatchableError as e:
    "raised " & $e.name & ": " & e.msg
  except Defect as e:
    "defect " & $e.name & ": " & e.msg

suite "the places that read a peer's text":

  test "Given the seeds of every target, when handled, then nothing is wrong":
    for entrance in Entrances:
      check entrance.seeds.len > 0
      for seed in entrance.seeds:
        let problem = wrong(entrance, seed)
        if problem.len > 0:
          checkpoint entrance.name & ": " & problem & " for " & seed.escape
        check problem.len == 0

  test "Given every input kept from fuzzing, when handled, then nothing is wrong":
    for entrance in Entrances:
      for input in found(entrance.name):
        let problem = wrong(entrance, input)
        if problem.len > 0:
          checkpoint entrance.name & ": " & problem & " for " & input.escape
        check problem.len == 0

  test "Given the corpus directory, when listed, then every directory in it is a target":
    var names: seq[string]
    for entrance in Entrances: names.add entrance.name
    for kind, dir in walkDir(Corpus):
      if kind == pcDir:
        check extractFilename(dir) in names
