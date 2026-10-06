# Configuration of every test in this directory.

import os

# Everything below is given as a path of its own, built from where this file
# is. A relative path in `out` is taken from the directory the compiler was
# started in, not from here: a test compiled from the repository's root put
# its program beside the repository, and the workers of a mutation run, each
# with a copy of the sources, all wrote the one program above their copies and
# then ran whichever of them had written it last.
let root = thisDir().parentDir

switch("path", root / "src")
switch("out", root / "build" / "tests" / projectName().splitFile.name)
switch("nimcache", root / "build" / "nimcache")

# Debug info for testing
switch("debuginfo")
switch("debugger", "native")
