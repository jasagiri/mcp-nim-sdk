## The YAML frontmatter of a SKILL.md, read into JSON.
##
## The skills extension asks a host to parse the frontmatter of the file it
## fetched and compare it field by field with the entry the server listed, so
## the SDK needs a reader. It reads the subset of YAML that skill files use:
## a top-level mapping whose values are plain or quoted scalars, block
## scalars (`|`, `>`), flow sequences of scalars (`[a, b]`), block sequences
## of scalars and nested block mappings. Anchors, aliases, tags, flow
## mappings, multi-document streams, tab indentation, duplicate keys and
## multi-line quoted scalars are refused with a FrontmatterError, so a file
## this reader cannot read is never loaded: the failure is the safe one.
##
## Plain scalars resolve as in the YAML core schema: `true`/`false`, `null`
## and `~`, integers and floats become JSON values, everything else a string.

import std/[json, parseutils, strutils, unicode]

type
  FrontmatterError* = object of CatchableError

  Frontmatter* = object
    fields*: JsonNode
      ## The frontmatter as a JSON object.
    body*: string
      ## What follows the closing `---` line.

  Line = object
    indent: int
    text: string
      ## Empty for a blank line and for a comment line.
    comment: string
      ## The text of a comment line. A block scalar owns it when it is
      ## indented as the scalar's content, it ends a plain scalar, and the
      ## other readers skip it.
    number: int

const Fence = "---"

{.push raises: [FrontmatterError].}

func fail(number: int, message: string): ref FrontmatterError {.raises: [].} =
  newException(FrontmatterError, "frontmatter line " & $number & ": " & message)

proc stripComment(text: string): string {.raises: [].} =
  ## A ` #` that starts a comment, outside quotes.
  var quote = '\0'
  for i, c in text:
    if quote != '\0':
      if c == quote:
        quote = '\0'
    elif c in {'"', '\''}:
      if i == 0 or text[i - 1] in {' ', '[', ',', ':'}:
        quote = c
    elif c == '#' and (i == 0 or text[i - 1] in {' ', '\t'}):
      return text[0 ..< i].strip(leading = false)
  text

proc unquoteDouble(text: string, number: int): string =
  var i = 1
  while i < text.len - 1:
    let c = text[i]
    if c != '\\':
      result.add c
      inc i
      continue
    inc i
    if i >= text.len - 1:
      raise fail(number, "a double-quoted scalar ends in a backslash")
    case text[i]
    of 'n': result.add '\n'
    of 't': result.add '\t'
    of 'r': result.add '\r'
    of '0': result.add '\0'
    of '"', '\\', '/': result.add text[i]
    of 'x', 'u', 'U':
      let digits = (if text[i] == 'x': 2 elif text[i] == 'u': 4 else: 8)
      if i + digits >= text.len:
        raise fail(number, "a short unicode escape")
      var code: int
      try:
        code = parseHexInt(text[i + 1 .. i + digits])
      except ValueError:
        raise fail(number, "a malformed unicode escape")
      if code < 0 or code > 0x10FFFF or code in 0xD800 .. 0xDFFF:
        raise fail(number, "a unicode escape outside the code space")
      result.add Rune(code).toUTF8
      i += digits
    else:
      raise fail(number, "unsupported escape \\" & text[i])
    inc i

proc unquoteSingle(text: string): string {.raises: [].} =
  var i = 1
  while i < text.len - 1:
    if text[i] == '\'' and text[i + 1] == '\'':
      result.add '\''
      i += 2
    else:
      result.add text[i]
      inc i

proc scalarOf(raw: string, number: int): JsonNode =
  let text = raw.strip()
  if text.len == 0 or text == "~" or text == "null" or text == "Null" or text == "NULL":
    return newJNull()
  if text[0] in {'&', '*', '!', '@', '`', '%'}:
    raise fail(number, "anchors, aliases, tags and directives are not supported: " & text)
  if text[0] == '"':
    if text.len < 2 or text[^1] != '"':
      raise fail(number, "a quoted scalar must end on its line")
    return %unquoteDouble(text, number)
  if text[0] == '\'':
    if text.len < 2 or text[^1] != '\'':
      raise fail(number, "a quoted scalar must end on its line")
    return %unquoteSingle(text)
  if text[0] == '{':
    raise fail(number, "flow mappings are not supported")
  case text
  of "true", "True", "TRUE": return %true
  of "false", "False", "FALSE": return %false
  else: discard
  # A number of the YAML 1.2 core schema holds only digits, a sign, a point and
  # an exponent. The character set is checked first because parseBiggestInt
  # and parseFloat also take `_` (`1_0`), `inf` and `nan`, which the schema
  # reads as text. A number that does not fit stays text: YAML would read it
  # as a float or string, and a skill's `name` or `description` is never one.
  if text.allCharsInSet(Digits + {'+', '-', '.', 'e', 'E'}):
    try:
      var asInt: int64
      if parseBiggestInt(text, asInt) == text.len:
        return %asInt
      var asFloat: float
      if parseFloat(text, asFloat) == text.len:
        return %asFloat
    except ValueError:
      discard
  %text

proc flowSequence(raw: string, number: int): JsonNode =
  let text = raw.strip()
  if text.len < 2 or text[^1] != ']':
    raise fail(number, "a flow sequence must end on its line")
  result = newJArray()
  let inner = text[1 ..< text.len - 1]
  var item = ""
  var quote = '\0'
  var items: seq[string]
  for c in inner:
    if quote != '\0':
      item.add c
      if c == quote:
        quote = '\0'
    elif c in {'"', '\''}:
      quote = c
      item.add c
    elif c == ',':
      items.add item
      item = ""
    elif c in {'[', ']', '{', '}'}:
      raise fail(number, "nested flow collections are not supported")
    else:
      item.add c
  if quote != '\0':
    raise fail(number, "an unterminated quote in a flow sequence")
  # What follows the last comma is an item only when it says something: `[a, ]`
  # is one item, as in YAML.
  if item.strip().len > 0:
    items.add item
  for entry in items:
    if entry.strip().len == 0:
      raise fail(number, "a flow sequence has an empty item")
    result.add scalarOf(entry, number)

proc valueOf(raw: string, number: int): JsonNode =
  let text = raw.strip()
  if text.startsWith("["):
    flowSequence(text, number)
  else:
    scalarOf(text, number)

proc splitKey(text: string, number: int): tuple[key, rest: string] =
  ## `key: rest` or `key:`; the key may be quoted.
  var key: string
  var i = 0
  if text[0] in {'"', '\''}:
    let quote = text[0]
    var j = 1
    while j < text.len:
      # A backslash in double quotes takes the next character with it, so an
      # escaped quote does not end the key; unquoteDouble reads the escape.
      if quote == '"' and text[j] == '\\':
        j += 2
        continue
      if text[j] == quote:
        # In single quotes a doubled quote is one quote of the key, not its end.
        if quote == '\'' and j + 1 < text.len and text[j + 1] == quote:
          j += 2
          continue
        break
      inc j
    if j >= text.len:
      raise fail(number, "an unterminated quoted key")
    key = text[0 .. j]
    key = if quote == '"': unquoteDouble(key, number) else: unquoteSingle(key)
    i = j + 1
    if i >= text.len or text[i] != ':':
      raise fail(number, "a quoted key must be followed by ':'")
  else:
    while i < text.len and not (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')):
      inc i
    if i >= text.len:
      raise fail(number, "expected 'key: value', got: " & text)
    key = text[0 ..< i].strip()
  if key.len == 0:
    raise fail(number, "an empty key")
  (key, text[i + 1 .. ^1])

type Reader = object
  lines: seq[Line]
  at: int

proc parseBlock(r: var Reader, indent: int): JsonNode

func fold(owned: seq[string]): string {.raises: [].} =
  ## The lines of a `>` scalar: a line break between two lines is a space, and
  ## n blank lines between them are n newlines. Next to a line indented deeper
  ## than the rest nothing folds: its break and the blank lines all stay.
  var blanks = 0
  var previous = ""
  for line in owned:
    if line.len == 0:
      inc blanks
      continue
    if previous.len == 0:
      result.add '\n'.repeat(blanks)
    elif previous[0] == ' ' or line[0] == ' ':
      result.add '\n'.repeat(blanks + 1)
    elif blanks == 0:
      result.add ' '
    else:
      result.add '\n'.repeat(blanks)
    result.add line
    previous = line
    blanks = 0

proc blockScalar(r: var Reader, header: string, parentIndent: int, number: int): JsonNode =
  ## `|` and `>` with an optional chomping indicator; the lines it owns are
  ## the following ones indented deeper than their key.
  let style = header[0]
  let chomp = if header.len > 1 and header[1] in {'-', '+'}: header[1] else: '\0'
  if header.len > (if chomp == '\0': 1 else: 2):
    raise fail(number, "unsupported block scalar header " & header)
  var owned: seq[string]
  var blockIndent = -1
  while r.at < r.lines.len:
    let line = r.lines[r.at]
    # A `#` line indented as the content is content.
    let content = if line.text.len > 0: line.text else: line.comment
    if content.len == 0:
      owned.add ""
      inc r.at
      continue
    # The scalar ends at the first line indented less than its content. A
    # comment there is a comment; the mapping refuses anything deeper after it.
    if line.indent <= parentIndent or line.indent < blockIndent:
      break
    if blockIndent < 0:
      blockIndent = line.indent
    owned.add ' '.repeat(line.indent - blockIndent) & content
    inc r.at
  var trailing = 0
  while owned.len > 0 and owned[^1].len == 0:
    owned.setLen(owned.len - 1)
    inc trailing
  var text = if style == '|': owned.join("\n") else: fold(owned)
  case chomp
  of '-': discard
  of '+': text.add '\n'.repeat(if owned.len > 0: 1 + trailing else: trailing)
  else:
    if owned.len > 0:
      text.add '\n'
  %text

proc parseMapping(r: var Reader, indent: int): JsonNode =
  result = newJObject()
  while r.at < r.lines.len:
    let line = r.lines[r.at]
    if line.text.len == 0:
      inc r.at
      continue
    if line.indent < indent:
      break
    if line.indent > indent:
      raise fail(line.number, "unexpected indentation")
    if line.text.startsWith("- "):
      raise fail(line.number, "a sequence item where a key was expected")
    let (key, rest) = splitKey(line.text, line.number)
    if result.hasKey(key):
      raise fail(line.number, "duplicate key '" & key & "'")
    inc r.at
    let value = stripComment(rest).strip()
    if value.len == 0:
      # A nested block, or null when nothing deeper follows.
      var next = r.at
      while next < r.lines.len and r.lines[next].text.len == 0:
        inc next
      if next < r.lines.len and (r.lines[next].indent > indent or
         (r.lines[next].indent == indent and r.lines[next].text.startsWith("- "))):
        r.at = next
        result[key] = parseBlock(r, r.lines[next].indent)
      else:
        result[key] = newJNull()
    elif value[0] in {'|', '>'}:
      result[key] = blockScalar(r, value, indent, line.number)
    else:
      var scalar = value
      # A plain scalar may continue on the following, deeper lines.
      if value[0] notin {'"', '\'', '['}:
        var blanks = 0
        # A comment ends the scalar: the mapping refuses a deeper line after it.
        var open = value == rest.strip()
        while open and r.at < r.lines.len and (r.lines[r.at].text.len == 0 or
              r.lines[r.at].indent > indent):
          let next = r.lines[r.at]
          if next.text.len > 0:
            let continuation = stripComment(next.text)
            if ": " in continuation or continuation.endsWith(":"):
              raise fail(next.number, "a mapping value is not allowed here")
            # A line break folds to a space; n blank lines before the line are n newlines.
            scalar.add (if blanks > 0: '\n'.repeat(blanks) else: " ") & continuation
            blanks = 0
            open = continuation == next.text
          elif next.comment.len > 0:
            break
          else:
            inc blanks
          inc r.at
      result[key] = valueOf(scalar, line.number)

proc parseSequence(r: var Reader, indent: int): JsonNode =
  result = newJArray()
  while r.at < r.lines.len:
    let line = r.lines[r.at]
    if line.text.len == 0:
      inc r.at
      continue
    if line.indent < indent:
      break
    let isItem = line.text.startsWith("- ") or line.text == "-"
    # A sequence written at the indent of its key ends at the key's next sibling.
    if line.indent == indent and not isItem:
      break
    if line.indent > indent:
      raise fail(line.number, "unexpected indentation")
    inc r.at
    let item = stripComment(line.text[1 .. ^1]).strip()
    if item.len == 0 or item.find(": ") >= 0 and item[0] notin {'"', '\''}:
      raise fail(line.number, "only scalar sequence items are supported")
    result.add valueOf(item, line.number)

proc parseBlock(r: var Reader, indent: int): JsonNode =
  let first = r.lines[r.at]
  if first.text.startsWith("- ") or first.text == "-":
    parseSequence(r, indent)
  else:
    parseMapping(r, indent)

{.pop.}

proc parseFrontmatter*(source: string): Frontmatter {.raises: [FrontmatterError].} =
  ## The frontmatter of `source`, a whole SKILL.md. Raises FrontmatterError
  ## when the file does not begin with a `---` block or the block is outside
  ## the supported subset.
  let all = source.splitLines()
  if all.len == 0 or all[0].strip(leading = false) != Fence:
    raise newException(FrontmatterError, "SKILL.md must begin with a '---' line")
  var closing = -1
  for i in 1 ..< all.len:
    if all[i].strip(leading = false) == Fence:
      closing = i
      break
  if closing < 0:
    raise newException(FrontmatterError, "the frontmatter has no closing '---' line")
  var reader = Reader()
  for i in 1 ..< closing:
    let raw = all[i]
    let leading = raw.len - raw.strip(trailing = false).len
    if '\t' in raw[0 ..< leading]:
      raise fail(i + 1, "tab indentation is not allowed in YAML")
    let text = raw.strip(leading = false)
    let trimmed = text.strip(trailing = false)
    if trimmed.len == 0 or trimmed[0] == '#':
      reader.lines.add Line(indent: text.len - trimmed.len, text: "", comment: trimmed)
    else:
      reader.lines.add Line(indent: text.len - trimmed.len, text: trimmed, number: i + 1)
  var fields = newJObject()
  var hasContent = false
  for line in reader.lines:
    if line.text.len > 0:
      hasContent = true
      break
  if hasContent:
    while reader.lines[reader.at].text.len == 0:
      inc reader.at
    let rootIndent = reader.lines[reader.at].indent
    fields = parseBlock(reader, rootIndent)
    if fields.kind != JObject:
      raise newException(FrontmatterError, "the frontmatter must be a mapping")
    if reader.at < reader.lines.len:
      raise fail(reader.lines[reader.at].number, "unexpected content")
  result.fields = fields
  result.body = all[closing + 1 .. ^1].join("\n")
