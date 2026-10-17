## The seeds of every fuzzing target, and the inputs fuzzing found, run with
## the other tests.
##
## Each file under tests/fuzz/corpus/<target>/ is an input that once made the
## library do something wrong. They are handled now, and stay so. The fuzzing
## itself is not a test: see tests/fuzz/fuzz_entrances.nim.
##
## Not tied to a specification: replaying the corpus is a way of testing,
## not something the SDK promises, and the targets include readers that no
## entry of the SDK reaches one input at a time (transport/address_policy,
## auth/oauth/{challenge,urls}, protocol/diagnostic). What the entries promise
## about malformed input is in the Scenarios of each entry. Until 2026-10-17
## this was the specification MCP-SEC-SWEEP-6.

import std/[unittest, os, strutils]
import fuzz   # foundation/nim-fuzz: replay, loadCorpus
import ../fuzz/targets

const Corpus = currentSourcePath().parentDir.parentDir / "fuzz" / "corpus"

proc kept(name: string): seq[string] =
  ## The inputs kept for a target; none when fuzzing has kept none for it.
  if dirExists(Corpus / name): loadCorpus(Corpus / name) else: @[]

proc said(name: string, findings: seq[Finding]) =
  for finding in findings:
    checkpoint name & ": " & $finding.kind & " " & finding.reason & " for " & finding.input.escape

suite "the places that read a peer's text":

  test "Given the seeds of every target, when handled, then nothing is wrong":
    for entrance in Entrances:
      check entrance.seeds.len > 0
      let findings = replay(FuzzTarget(entrance.target), entrance.seeds)
      said(entrance.name, findings)
      check findings.len == 0

  test "Given every input kept from fuzzing, when handled, then nothing is wrong":
    for entrance in Entrances:
      let findings = replay(FuzzTarget(entrance.target), kept(entrance.name))
      said(entrance.name, findings)
      check findings.len == 0

  test "Given the corpus directory, when listed, then every directory in it is a target":
    var names: seq[string]
    for entrance in Entrances: names.add entrance.name
    for kind, dir in walkDir(Corpus):
      if kind == pcDir:
        check extractFilename(dir) in names
