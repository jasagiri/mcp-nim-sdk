## The regular expressions of JSON Schema `pattern` and `patternProperties`.
##
## JSON Schema 2020-12 asks for ECMA-262 syntax and says a pattern matches
## when it matches anywhere in the string. The standard library has no engine
## of that kind that works without a system library, so this is a small
## one: literals, `.`, classes (`[a-z]`, `\d`, `\w`, `\s` and their
## negations), anchors, `\b`, groups (capturing, `(?:`), alternation, the
## lookaheads `(?=` and `(?!`, and the quantifiers `* + ? {n} {n,} {n,m}`
## with their lazy forms. Back references and Unicode property escapes are
## not supported; a pattern that uses one is rejected, never ignored.
##
## Both the pattern and the text can be hostile (a tool's arguments, or an
## `outputSchema` from a server one does not trust), so the engine does not
## backtrack. A pattern is compiled to a program for a Thompson NFA and
## matching advances the set of live states over the text one character at a
## time: the work is at most (text length) x (program size), with no stack
## that grows with the text. The syntax allows this because the supported
## constructs only ask whether a match exists, and the lookaheads are
## zero-width: each one is a sub-program that runs from one position and is
## remembered per position. Lazy and greedy quantifiers differ only in which
## match is found first, which a yes/no answer does not show.
##
## Limits (`RegexLimits`, `DefaultMaxRegexSteps`) turn a pattern that is too
## large to check into a `RegexLimitError`; a pattern is never taken as
## matching or not matching because a limit was reached.

import std/[unicode, strutils, tables]

type
  RegexError* = object of ValueError
    ## The pattern is malformed or uses syntax this engine does not support.

  RegexLimitError* = object of RegexError
    ## The pattern or the work it asks for is above a limit; whether it
    ## matches is not known.

  RegexLimits* = object
    maxPatternLength*: int
      ## Characters in the pattern.
    maxRepeat*: int
      ## The largest count in `{n}`, `{n,}` and `{n,m}`.
    maxProgramSize*: int
      ## Instructions after the counted repetitions are expanded, over the
      ## pattern and its lookaheads together.
    maxNesting*: int
      ## Groups inside groups.

  RangeSet = seq[tuple[lo, hi: int32]]

  NodeKind = enum
    nkChar, nkAny, nkSet, nkSeq, nkAlt, nkRepeat, nkBol, nkEol, nkWordBoundary,
    nkNotWordBoundary, nkLookahead, nkNotLookahead

  Node = ref object
    case kind: NodeKind
    of nkChar: ch: int32
    of nkSet:
      ranges: RangeSet
      negated: bool
    of nkSeq, nkAlt: children: seq[Node]
    of nkRepeat:
      body: Node
      min, max: int
    of nkLookahead, nkNotLookahead: look: Node
    else: discard

  Parser = object
    src: seq[Rune]
    pos: int
    depth: int
    limits: RegexLimits

const
  DigitSet: RangeSet = @[(int32('0'), int32('9'))]
  WordSet: RangeSet = @[(int32('0'), int32('9')), (int32('A'), int32('Z')),
                        (int32('_'), int32('_')), (int32('a'), int32('z'))]
  SpaceSet: RangeSet = @[(9'i32, 13'i32), (32'i32, 32'i32), (0xA0'i32, 0xA0'i32),
                         (0x1680'i32, 0x1680'i32), (0x2000'i32, 0x200A'i32),
                         (0x2028'i32, 0x2029'i32), (0x202F'i32, 0x202F'i32),
                         (0x205F'i32, 0x205F'i32), (0x3000'i32, 0x3000'i32),
                         (0xFEFF'i32, 0xFEFF'i32)]
  LineTerminators: RangeSet = @[(10'i32, 10'i32), (13'i32, 13'i32), (0x2028'i32, 0x2029'i32)]
  NoRepeatLimit = high(int)

  DefaultRegexLimits* = RegexLimits(
    maxPatternLength: 4096,  # tool schemas carry short patterns; 4 KiB is generous
    maxRepeat: 1000,         # `{1,255}` is common, `{1000000}` is an expansion bomb
    maxProgramSize: 50_000,  # 50 instructions per pattern character on average
    maxNesting: 64)

  DefaultMaxRegexSteps* = 200_000_000
    ## What one `isMatch` may spend by default, in state visits (about a
    ## second). `^[a-z]+$` over 4 MiB spends under 20 million.

proc fail(p: Parser, what: string) {.noreturn.} =
  raise newException(RegexError, what & " at position " & $p.pos)

proc failLimit(p: Parser, what: string) {.noreturn.} =
  raise newException(RegexLimitError, what & " at position " & $p.pos)

func atEnd(p: Parser): bool = p.pos >= p.src.len
func peek(p: Parser): int32 = int32(p.src[p.pos])

func asciiAt(p: Parser, at: int): char =
  ## The character at `at` for a `case` over the syntax, which is all ASCII.
  ## A code point above U+007F is none of the syntax; it is given as a byte
  ## no branch names. `char` of such a code point is a RangeDefect from
  ## U+0100 on, which a pattern holding "あ" outside a class once was.
  let c = int32(p.src[at])
  if c <= 0x7F: char(c) else: '\x80'

func ascii(p: Parser): char = p.asciiAt(p.pos)

proc complement(r: RangeSet): RangeSet =
  ## The ranges of `r` are assumed sorted and disjoint (the escapes above).
  var next = 0'i32
  for (lo, hi) in r:
    if lo > next:
      result.add (next, lo - 1)
    next = hi + 1
  result.add (next, 0x10FFFF'i32)

proc parseAlternation(p: var Parser): Node

proc parseEscapeChar(p: var Parser): int32 =
  ## The character a single-character escape stands for; the backslash is
  ## already consumed.
  if p.atEnd:
    p.fail("a pattern ends with a backslash")
  let raw = p.peek
  let c = p.ascii
  inc p.pos
  case c
  of 'n': 10
  of 't': 9
  of 'r': 13
  of 'f': 12
  of 'v': 11
  of '0': 0
  of 'x', 'u':
    let digits = if c == 'x': 2 else: 4
    if p.pos + digits > p.src.len:
      p.fail("a \\" & c & " escape needs " & $digits & " hex digits")
    var text = ""
    for i in 0 ..< digits:
      text.add p.asciiAt(p.pos + i)
    p.pos += digits
    try:
      int32(parseHexInt(text))
    except ValueError:
      p.fail("'" & text & "' is not a hex number")
  of 'p', 'P':
    p.fail("Unicode property escapes are not supported")
  of '1' .. '9':
    p.fail("back references are not supported")
  else: raw

proc classEscape(c: char): RangeSet =
  case c
  of 'd': DigitSet
  of 'D': DigitSet.complement
  of 'w': WordSet
  of 'W': WordSet.complement
  of 's': SpaceSet
  of 'S': SpaceSet.complement
  else: @[]

proc parseClass(p: var Parser): Node =
  ## After the opening bracket.
  result = Node(kind: nkSet)
  if not p.atEnd and p.peek == int32('^'):
    result.negated = true
    inc p.pos
  while true:
    if p.atEnd:
      p.fail("a character class is not closed")
    if p.peek == int32(']'):
      # ECMA-262 has no "]" as the first member: `[]` is the empty class and
      # `[^]` any character.
      inc p.pos
      return
    var lo: int32
    if p.peek == int32('\\'):
      inc p.pos
      if p.atEnd:
        p.fail("a pattern ends with a backslash")
      let escaped = classEscape(p.ascii)
      if escaped.len > 0:
        inc p.pos
        result.ranges.add escaped
        continue
      if p.ascii == 'b':
        inc p.pos
        lo = 8'i32
      else:
        lo = p.parseEscapeChar()
    else:
      lo = p.peek
      inc p.pos
    var hi = lo
    if p.pos + 1 < p.src.len and p.peek == int32('-') and p.src[p.pos + 1] != Rune(']'):
      inc p.pos
      if p.peek == int32('\\'):
        inc p.pos
        hi = p.parseEscapeChar()
      else:
        hi = p.peek
        inc p.pos
      if hi < lo:
        p.fail("a character range runs backwards")
    result.ranges.add (lo, hi)

proc parseNumber(p: var Parser): int =
  var text = ""
  while not p.atEnd and p.ascii in {'0' .. '9'}:
    text.add p.ascii
    inc p.pos
  if text.len == 0: return -1
  # Ten digits already exceed every limit; parseInt must not see an overflow.
  if text.len > 9:
    p.failLimit("a repetition count has more than 9 digits")
  parseInt(text)

proc parseQuantifier(p: var Parser, atom: Node): Node =
  if p.atEnd:
    return atom
  var min, max: int
  case p.ascii
  of '*': min = 0; max = NoRepeatLimit; inc p.pos
  of '+': min = 1; max = NoRepeatLimit; inc p.pos
  of '?': min = 0; max = 1; inc p.pos
  of '{':
    let start = p.pos
    inc p.pos
    min = p.parseNumber()
    if min < 0:
      p.pos = start
      return atom  # ECMA-262 reads a brace that is no quantifier as a literal
    max = min
    if not p.atEnd and p.peek == int32(','):
      inc p.pos
      max = p.parseNumber()
      if max < 0: max = NoRepeatLimit
    if p.atEnd or p.peek != int32('}'):
      p.pos = start
      return atom  # Annex B: a brace that is not closed is a literal, as is {2x}
    inc p.pos
    if max < min:
      p.fail("a repetition runs backwards")
    if min > p.limits.maxRepeat or (max != NoRepeatLimit and max > p.limits.maxRepeat):
      p.failLimit("a repetition count is above " & $p.limits.maxRepeat)
  else:
    return atom
  result = Node(kind: nkRepeat, body: atom, min: min, max: max)
  if not p.atEnd and p.peek == int32('?'):
    # A lazy quantifier. Whether a string matches does not depend on which
    # of the possible matches is preferred, so there is nothing to remember.
    inc p.pos

proc parseAtom(p: var Parser): Node =
  let c = p.peek
  let syntax = p.ascii
  inc p.pos
  case syntax
  of '.': Node(kind: nkAny)
  of '^': Node(kind: nkBol)
  of '$': Node(kind: nkEol)
  of '[': p.parseClass()
  of '(':
    var kind = nkSeq
    if p.pos + 1 < p.src.len and p.peek == int32('?'):
      case p.asciiAt(p.pos + 1)
      of ':': p.pos += 2
      of '=': p.pos += 2; kind = nkLookahead
      of '!': p.pos += 2; kind = nkNotLookahead
      else: p.fail("group syntax is not supported")
    inc p.depth
    if p.depth > p.limits.maxNesting:
      p.failLimit("groups are nested deeper than " & $p.limits.maxNesting)
    let inner = p.parseAlternation()
    dec p.depth
    if p.atEnd or p.peek != int32(')'):
      p.fail("a group is not closed")
    inc p.pos
    case kind
    of nkLookahead: Node(kind: nkLookahead, look: inner)
    of nkNotLookahead: Node(kind: nkNotLookahead, look: inner)
    else: inner
  of '\\':
    if p.atEnd:
      p.fail("a pattern ends with a backslash")
    case p.ascii
    of 'b': inc p.pos; Node(kind: nkWordBoundary)
    of 'B': inc p.pos; Node(kind: nkNotWordBoundary)
    of 'd', 'D', 'w', 'W', 's', 'S':
      let escaped = p.ascii
      inc p.pos
      Node(kind: nkSet, ranges: classEscape(escaped))
    else: Node(kind: nkChar, ch: p.parseEscapeChar())
  of '*', '+', '?':
    dec p.pos
    p.fail("a quantifier has nothing to repeat")
  else: Node(kind: nkChar, ch: c)

proc parseSequence(p: var Parser): Node =
  result = Node(kind: nkSeq)
  while not p.atEnd and p.peek != int32('|') and p.peek != int32(')'):
    result.children.add p.parseQuantifier(p.parseAtom())

proc parseAlternation(p: var Parser): Node =
  let first = p.parseSequence()
  if p.atEnd or p.peek != int32('|'):
    return first
  result = Node(kind: nkAlt, children: @[first])
  while not p.atEnd and p.peek == int32('|'):
    inc p.pos
    result.children.add p.parseSequence()


# Compiling to a Thompson NFA

type
  InstKind = enum
    ikChar, ikAny, ikSet, ikSplit, ikJmp, ikBol, ikEol, ikWordBoundary,
    ikNotWordBoundary, ikLook, ikMatch

  Inst = object
    kind: InstKind
    ch: int32          # ikChar
    setIndex: int      # ikSet
    negated: bool      # ikLook: a negative lookahead
    x, y: int          # ikSplit: both targets; ikJmp: x; ikLook: x is the sub-program

  Program = seq[Inst]
    ## Ends with ikMatch, so `pc + 1` is always a valid successor of a
    ## consuming or asserting instruction.

  CharSet = tuple[ranges: RangeSet, negated: bool]

  RegexCode = ref object
    programs: seq[Program]  # [0] is the pattern, the rest are lookaheads
    sets: seq[CharSet]
    size: int

  Regex* = object
    code: RegexCode

  Compiler = object
    code: RegexCode
    limits: RegexLimits
    work: int

proc size*(re: Regex): int =
  ## Instructions in the compiled pattern; what compiling it cost.
  re.code.size

proc emit(c: var Compiler, program: int, inst: Inst): int =
  inc c.code.size
  if c.code.size > c.limits.maxProgramSize:
    raise newException(RegexLimitError,
      "the pattern needs more than " & $c.limits.maxProgramSize & " instructions")
  c.code.programs[program].add inst
  c.code.programs[program].high

proc compileNode(c: var Compiler, program: int, n: Node) =
  # Repetitions can nest around bodies that emit nothing (`(?:){1000}`), so
  # the size check in `emit` alone would not stop `((?:){1000}){1000}...`.
  inc c.work
  if c.work > 4 * c.limits.maxProgramSize:
    raise newException(RegexLimitError, "the pattern expands to too much work")
  case n.kind
  of nkChar: discard c.emit(program, Inst(kind: ikChar, ch: n.ch))
  of nkAny: discard c.emit(program, Inst(kind: ikAny))
  of nkSet:
    c.code.sets.add (n.ranges, n.negated)
    discard c.emit(program, Inst(kind: ikSet, setIndex: c.code.sets.high))
  of nkSeq:
    for child in n.children:
      c.compileNode(program, child)
  of nkAlt:
    var jumps: seq[int]
    for index, child in n.children:
      if index < n.children.high:
        let split = c.emit(program, Inst(kind: ikSplit))
        c.code.programs[program][split].x = split + 1
        c.compileNode(program, child)
        jumps.add c.emit(program, Inst(kind: ikJmp))
        c.code.programs[program][split].y = c.code.programs[program].len
      else:
        c.compileNode(program, child)
    for jump in jumps:
      c.code.programs[program][jump].x = c.code.programs[program].len
  of nkRepeat:
    for _ in 0 ..< n.min:
      c.compileNode(program, n.body)
    if n.max == NoRepeatLimit:
      let split = c.emit(program, Inst(kind: ikSplit))
      c.code.programs[program][split].x = split + 1
      c.compileNode(program, n.body)
      discard c.emit(program, Inst(kind: ikJmp, x: split))
      c.code.programs[program][split].y = c.code.programs[program].len
    else:
      var splits: seq[int]
      for _ in n.min ..< n.max:
        let split = c.emit(program, Inst(kind: ikSplit))
        c.code.programs[program][split].x = split + 1
        splits.add split
        c.compileNode(program, n.body)
      for split in splits:
        c.code.programs[program][split].y = c.code.programs[program].len
  of nkBol: discard c.emit(program, Inst(kind: ikBol))
  of nkEol: discard c.emit(program, Inst(kind: ikEol))
  of nkWordBoundary: discard c.emit(program, Inst(kind: ikWordBoundary))
  of nkNotWordBoundary: discard c.emit(program, Inst(kind: ikNotWordBoundary))
  of nkLookahead, nkNotLookahead:
    c.code.programs.add @[]
    let sub = c.code.programs.high
    c.compileNode(sub, n.look)
    discard c.emit(sub, Inst(kind: ikMatch))
    discard c.emit(program, Inst(kind: ikLook, x: sub, negated: n.kind == nkNotLookahead))

proc compileRegex*(pattern: string, limits = DefaultRegexLimits): Regex =
  ## Raises RegexError for a malformed or unsupported pattern, and
  ## RegexLimitError (a RegexError) for one above `limits`.
  let runes = pattern.toRunes
  if runes.len > limits.maxPatternLength:
    raise newException(RegexLimitError,
      "the pattern has " & $runes.len & " characters; the limit is " &
      $limits.maxPatternLength)
  var p = Parser(src: runes, limits: limits)
  let root = p.parseAlternation()
  if not p.atEnd:
    p.fail("unbalanced parenthesis")
  var c = Compiler(code: RegexCode(programs: @[newSeq[Inst]()]), limits: limits)
  c.compileNode(0, root)
  discard c.emit(0, Inst(kind: ikMatch))
  Regex(code: c.code)

# Matching

type
  Run = ref object
    code: RegexCode
    budget: int
    lookResults: Table[(int, int), bool]  # (sub-program, position) -> it matches there

func inRanges(r: RangeSet, c: int32): bool =
  for (lo, hi) in r:
    if c >= lo and c <= hi:
      return true

func isWord(text: openArray[Rune], i: int): bool =
  i >= 0 and i < text.len and WordSet.inRanges(int32(text[i]))

proc charge(run: Run) =
  dec run.budget
  if run.budget < 0:
    raise newException(RegexLimitError, "matching spent its step budget")

proc matchesFrom(run: Run, program: int, text: openArray[Rune], start: int,
                 anchored: bool): bool

proc lookMatches(run: Run, sub: int, text: openArray[Rune], i: int): bool =
  let key = (sub, i)
  if key notin run.lookResults:
    run.lookResults[key] = run.matchesFrom(sub, text, i, anchored = true)
  run.lookResults[key]

proc reach(run: Run, program: int, text: openArray[Rune], first, i: int,
           marks: var seq[int], gen: int, live: var seq[int],
           pending: var seq[int]): bool =
  ## Follows the instructions that consume nothing from `first` at text
  ## position `i`, adding the ones that consume a character to `live`.
  ## True when ikMatch is among them.
  pending.setLen 0
  pending.add first
  while pending.len > 0:
    let pc = pending.pop
    if marks[pc] == gen:
      continue
    marks[pc] = gen
    run.charge()
    let inst = run.code.programs[program][pc]
    case inst.kind
    of ikChar, ikAny, ikSet: live.add pc
    of ikSplit:
      pending.add inst.y
      pending.add inst.x
    of ikJmp: pending.add inst.x
    of ikBol:
      if i == 0: pending.add pc + 1
    of ikEol:
      if i == text.len: pending.add pc + 1
    of ikWordBoundary:
      if text.isWord(i - 1) != text.isWord(i): pending.add pc + 1
    of ikNotWordBoundary:
      if text.isWord(i - 1) == text.isWord(i): pending.add pc + 1
    of ikLook:
      if run.lookMatches(inst.x, text, i) != inst.negated: pending.add pc + 1
    of ikMatch: return true

proc matchesFrom(run: Run, program: int, text: openArray[Rune], start: int,
                 anchored: bool): bool =
  ## Whether the program matches starting at `start` (anchored) or starting
  ## anywhere from `start` on.
  var
    marks = newSeq[int](run.code.programs[program].len)
    live, next, pending: seq[int]
    gen = 1
    i = start
  while true:
    if (not anchored or i == start) and
       run.reach(program, text, 0, i, marks, gen, live, pending):
      return true
    if i >= text.len or (anchored and live.len == 0):
      return false
    let c = int32(text[i])
    inc gen
    next.setLen 0
    for pc in live:
      run.charge()
      let inst = run.code.programs[program][pc]
      let consumed = case inst.kind
        of ikChar: c == inst.ch
        of ikAny: not LineTerminators.inRanges(c)
        of ikSet:
          let set = run.code.sets[inst.setIndex]
          set.ranges.inRanges(c) != set.negated
        else: false
      if consumed and run.reach(program, text, pc + 1, i + 1, marks, gen, next, pending):
        return true
    swap(live, next)
    inc i

proc isMatch*(re: Regex, text: string, budget: var int): bool =
  ## Whether the pattern matches anywhere in `text`. `budget` is the number
  ## of state visits still allowed and is reduced by what this match spent,
  ## so one budget can cover many matches. Raises RegexLimitError when it
  ## runs out.
  let runes = text.toRunes
  let run = Run(code: re.code, budget: budget)
  try:
    result = run.matchesFrom(0, runes, 0, anchored = false)
  finally:
    budget = run.budget
