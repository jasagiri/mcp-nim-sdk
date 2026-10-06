## Which programs a change can affect.
##
##   affected BASE CACHE FILE...
##
## prints each FILE (a Nim program, such as a test) that has to be built and
## run again after the changes since the commit BASE: the file itself or a
## source the compiler last built it from differs from BASE, there is no
## record of that build in CACHE (`<name>.json`, which the compiler writes
## into its cache directory), or something changed that no such record
## accounts for (the build's own files, test data).
##
## `nimble testAllVersions` uses it with MCP_TEST_BASE.

import std/[json, os, osproc, sets, strutils]

proc gitLines(arguments: openArray[string]): seq[string] =
  let (output, code) = execCmdEx("git " & quoteShellCommand(arguments))
  if code != 0:
    raise newException(OSError, "git " & arguments.join(" ") & " failed: " & output.strip())
  for line in output.splitLines():
    if line.strip().len > 0:
      result.add line.strip()

proc changedSince*(base: string): HashSet[string] =
  ## Paths, relative to the repository, that differ from `base`; files git
  ## does not track yet are among them.
  for path in gitLines(["diff", "--name-only", base, "--"]):
    result.incl path
  for path in gitLines(["ls-files", "--others", "--exclude-standard"]):
    result.incl path

func unaccountable*(changed: HashSet[string]): bool =
  ## Whether `changed` holds something every program may depend on without
  ## the compiler knowing: the package file, or data the tests read.
  for path in changed:
    if path.endsWith(".nimble"):
      return true
    if path.startsWith("tests/") and not path.endsWith(".nim") and
       not path.startsWith("tests/mutation/"):
      return true
  false

proc sourcesOf*(record, root: string): seq[string] =
  ## The sources under `root` that the compiler's record names, relative to it.
  let prefix = root.normalizedPath & "/"
  for source in parseFile(record)["depfiles"]:
    let path = source[0].getStr()
    if path.startsWith(prefix):
      result.add path[prefix.len .. ^1]

proc affected*(file, cache, root: string, changed: HashSet[string]): bool =
  if file in changed:
    return true
  let record = cache / file.splitFile.name & ".json"
  if not fileExists(record):
    return true
  for source in sourcesOf(record, root):
    if source in changed:
      return true
  false

when isMainModule:
  let arguments = commandLineParams()
  if arguments.len < 2:
    quit("usage: affected BASE CACHE FILE...", 2)
  let changed = changedSince(arguments[0])
  let everything = unaccountable(changed)
  for file in arguments[2 .. ^1]:
    if everything or affected(file, arguments[1], getCurrentDir(), changed):
      echo file
