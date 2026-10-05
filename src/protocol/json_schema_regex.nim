## The regular expressions of JSON Schema `pattern` and `patternProperties`.
##
## JSON Schema 2020-12 asks for ECMA-262 syntax and says a pattern matches
## when it matches anywhere in the string. The standard library has no engine
## of that kind that works without a system library, so this is a small
## backtracking one: literals, `.`, classes (`[a-z]`, `\d`, `\w`, `\s` and
## their negations), anchors, `\b`, groups (capturing, `(?:`), alternation,
## the lookaheads `(?=` and `(?!`, and the quantifiers `* + ? {n} {n,} {n,m}`
## with their lazy forms. Back references and Unicode property escapes are
## not supported; a pattern that uses one is rejected, never ignored.

import std/[unicode, strutils]

type
  RegexError* = object of ValueError
    ## The pattern is malformed or uses syntax this engine does not support.

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
      lazy: bool
    of nkLookahead, nkNotLookahead: look: Node
    else: discard

  Regex* = object
    root: Node

  Parser = object
    src: seq[Rune]
    pos: int

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

proc fail(p: Parser, what: string) {.noreturn.} =
  raise newException(RegexError, what & " at position " & $p.pos)

func atEnd(p: Parser): bool = p.pos >= p.src.len
func peek(p: Parser): int32 = int32(p.src[p.pos])

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
  let c = char(p.peek)
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
      text.add char(p.src[p.pos + i])
    p.pos += digits
    try:
      int32(parseHexInt(text))
    except ValueError:
      p.fail("'" & text & "' is not a hex number")
  of 'p', 'P':
    p.fail("Unicode property escapes are not supported")
  of '1' .. '9':
    p.fail("back references are not supported")
  else: int32(c)

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
  var first = true
  while true:
    if p.atEnd:
      p.fail("a character class is not closed")
    if p.peek == int32(']') and not first:
      inc p.pos
      return
    first = false
    var lo: int32
    if p.peek == int32('\\'):
      inc p.pos
      if p.atEnd:
        p.fail("a pattern ends with a backslash")
      let escaped = classEscape(char(p.peek))
      if escaped.len > 0:
        inc p.pos
        result.ranges.add escaped
        continue
      lo = (if char(p.peek) == 'b': (inc p.pos; 8'i32) else: p.parseEscapeChar())
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
  while not p.atEnd and char(p.peek) in {'0' .. '9'}:
    text.add char(p.peek)
    inc p.pos
  if text.len == 0: -1 else: parseInt(text)

proc parseQuantifier(p: var Parser, atom: Node): Node =
  if p.atEnd:
    return atom
  var min, max: int
  case char(p.peek)
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
      p.fail("a repetition is not closed")
    inc p.pos
    if max < min:
      p.fail("a repetition runs backwards")
  else:
    return atom
  result = Node(kind: nkRepeat, body: atom, min: min, max: max)
  if not p.atEnd and p.peek == int32('?'):
    result.lazy = true
    inc p.pos

proc parseAtom(p: var Parser): Node =
  let c = p.peek
  inc p.pos
  case char(c)
  of '.': Node(kind: nkAny)
  of '^': Node(kind: nkBol)
  of '$': Node(kind: nkEol)
  of '[': p.parseClass()
  of '(':
    var kind = nkSeq
    if p.pos + 1 < p.src.len and p.peek == int32('?'):
      case char(p.src[p.pos + 1])
      of ':': p.pos += 2
      of '=': p.pos += 2; kind = nkLookahead
      of '!': p.pos += 2; kind = nkNotLookahead
      else: p.fail("group syntax is not supported")
    let inner = p.parseAlternation()
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
    case char(p.peek)
    of 'b': inc p.pos; Node(kind: nkWordBoundary)
    of 'B': inc p.pos; Node(kind: nkNotWordBoundary)
    of 'd', 'D', 'w', 'W', 's', 'S':
      let escaped = char(p.peek)
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

proc compileRegex*(pattern: string): Regex =
  ## Raises RegexError for a malformed or unsupported pattern.
  var p = Parser(src: pattern.toRunes)
  let root = p.parseAlternation()
  if not p.atEnd:
    p.fail("unbalanced parenthesis")
  Regex(root: root)

# Matching

type Continuation = proc(i: int): bool

func inRanges(r: RangeSet, c: int32): bool =
  for (lo, hi) in r:
    if c >= lo and c <= hi:
      return true

func isWord(text: seq[Rune], i: int): bool =
  i >= 0 and i < text.len and WordSet.inRanges(int32(text[i]))

proc step(n: Node, text: seq[Rune], i: int, k: Continuation): bool

proc repeatFrom(n: Node, text: seq[Rune], i, count: int, k: Continuation): bool =
  let again = proc(): bool =
    n.max > count and step(n.body, text, i, proc(j: int): bool =
      # An iteration that consumed nothing cannot help once the minimum is met.
      (j != i or count < n.min) and repeatFrom(n, text, j, count + 1, k))
  let stop = proc(): bool = count >= n.min and k(i)
  if n.lazy: stop() or again() else: again() or stop()

proc step(n: Node, text: seq[Rune], i: int, k: Continuation): bool =
  case n.kind
  of nkChar: i < text.len and int32(text[i]) == n.ch and k(i + 1)
  of nkAny:
    i < text.len and not LineTerminators.inRanges(int32(text[i])) and k(i + 1)
  of nkSet:
    i < text.len and n.ranges.inRanges(int32(text[i])) != n.negated and k(i + 1)
  of nkSeq:
    proc chain(index, at: int): bool =
      if index == n.children.len: k(at)
      else: step(n.children[index], text, at, proc(j: int): bool = chain(index + 1, j))
    chain(0, i)
  of nkAlt:
    for child in n.children:
      if step(child, text, i, k):
        return true
    false
  of nkRepeat: repeatFrom(n, text, i, 0, k)
  of nkBol: i == 0 and k(i)
  of nkEol: i == text.len and k(i)
  of nkWordBoundary: text.isWord(i - 1) != text.isWord(i) and k(i)
  of nkNotWordBoundary: text.isWord(i - 1) == text.isWord(i) and k(i)
  of nkLookahead: step(n.look, text, i, proc(j: int): bool = true) and k(i)
  of nkNotLookahead: not step(n.look, text, i, proc(j: int): bool = true) and k(i)

proc isMatch*(re: Regex, text: string): bool =
  ## Whether the pattern matches anywhere in `text`.
  let runes = text.toRunes
  for start in 0 .. runes.len:
    if step(re.root, runes, start, proc(j: int): bool = true):
      return true
