## Writes, for each entrance of targets.nim, what libFuzzer reads beside the
## program: <dir>/<name>/seeds/ (the seeds and the inputs kept in corpus/),
## <dir>/<name>/dict (the words, in libFuzzer's dictionary format) and
## <dir>/<name>/max_len.

import std/[os, strutils]
import fuzz   # foundation/nim-fuzz: loadCorpus
import ./targets

let dir = paramStr(1)
for entrance in Entrances:
  let base = dir / entrance.name
  createDir(base / "seeds")
  var inputs = entrance.seeds
  let kept = currentSourcePath().parentDir / "corpus" / entrance.name
  if dirExists(kept): inputs.add loadCorpus(kept)
  for i, input in inputs:
    writeFile(base / "seeds" / ("seed-" & $i), input)
  var dict = ""
  for word in entrance.words:
    var escaped = ""
    for c in word:
      if c in {' ' .. '~'} and c notin {'"', '\\'}: escaped.add c
      else: escaped.add "\\x" & toHex(ord(c), 2)
    dict.add "\"" & escaped & "\"\n"
  writeFile(base / "dict", dict)
  writeFile(base / "max_len", $entrance.maxLen)
  echo entrance.name
