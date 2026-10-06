## JSON Schema validation for the schemas MCP carries: a tool's `inputSchema`
## and `outputSchema`.
##
## 2025-11-25 and later: a schema without `$schema` is JSON Schema 2020-12,
## and an implementation must support at least that dialect. This module
## validates 2020-12 and draft-07 (the dialect the 2025-11-25 tools page uses
## as its example of an explicit `$schema`). Any other `$schema` raises
## `UnsupportedDialectError`: a schema that cannot be checked is reported,
## never taken as satisfied.
##
## Keywords checked: `type`, `enum`, `const`, `properties`, `required`,
## `additionalProperties`, `patternProperties`, `propertyNames`, `items`,
## `prefixItems` (draft-07: `items` as an array and `additionalItems`),
## `contains`, `minContains`, `maxContains`, `minItems`, `maxItems`,
## `uniqueItems`, `minLength`, `maxLength`, `pattern`, `minimum`, `maximum`,
## `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minProperties`,
## `maxProperties`, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`,
## `dependentRequired`, `dependentSchemas` (draft-07: `dependencies`) and
## local `$ref` (`#`, `#/pointer`). `format` and the other annotation keywords
## assert nothing, as the specification says. Keywords that would change the
## outcome but are not implemented (`unevaluatedProperties`,
## `unevaluatedItems`, `$dynamicRef`, `$recursiveRef`, `contentSchema`, a
## `$ref` that leaves the document) raise `UnsupportedKeywordError`.
##
## Neither side of a validation is trusted: the instance can be a tool's
## arguments, the schema an `outputSchema` from a server. `SchemaLimits` bounds
## the nesting, the total work and the regular expression work of one
## `validate`; a validation that reaches a bound raises `SchemaLimitError`
## and never reports the instance as conforming. A `$ref` that comes back to
## itself without moving into the instance can never finish and is reported
## as an invalid schema.

import std/[json, math, strutils, tables, unicode]
import ./json_schema_regex

type
  SchemaDialect* = enum
    sdDraft07 = "http://json-schema.org/draft-07/schema#"
    sdDraft202012 = "https://json-schema.org/draft/2020-12/schema"

  SchemaViolation* = object
    path*: string
      ## JSON Pointer to the part of the instance that failed; empty for the
      ## instance itself.
    message*: string

  InvalidSchemaError* = object of ValueError
    ## The schema is not a schema (wrong keyword type, dangling `$ref`).
  UnsupportedDialectError* = object of InvalidSchemaError
  UnsupportedKeywordError* = object of InvalidSchemaError
  SchemaLimitError* = object of InvalidSchemaError
    ## The schema or the instance is above a limit of `SchemaLimits`, so
    ## whether the instance conforms is not known.

  SchemaLimits* = object
    maxDepth*: int
      ## Schemas inside schemas, along one path. Every level of the instance
      ## and every `$ref` hop is one, so this bounds the stack.
    maxChecks*: int
      ## Schema applications in one `validate`. Bounds `allOf`/`$ref` fan-out
      ## that multiplies at every level, and large instances with large schemas.
    maxRegexSteps*: int
      ## State visits of all `pattern` and `patternProperties` matches in one
      ## `validate`, plus the size of every pattern compiled.
    regex*: RegexLimits
      ## Size limits of each pattern.

const
  DefaultDialect* = sdDraft202012
    ## What a schema without `$schema` is (2025-11-25, basic/index).

  DefaultSchemaLimits* = SchemaLimits(
    maxDepth: 256,           # real schemas nest a dozen levels; a frame is a few hundred bytes
    maxChecks: 10_000_000,   # an array of a million small objects is about 3 million
    maxRegexSteps: DefaultMaxRegexSteps,
    regex: DefaultRegexLimits)

  UnsupportedKeywords = ["unevaluatedProperties", "unevaluatedItems",
                         "$dynamicRef", "$recursiveRef", "contentSchema"]

proc dialectOf*(schema: JsonNode): SchemaDialect =
  ## The dialect `schema` declares. Raises UnsupportedDialectError for one
  ## this module cannot check.
  if schema.isNil or schema.kind != JObject or not schema.hasKey("$schema"):
    return DefaultDialect
  let declared = schema["$schema"]
  if declared.kind != JString:
    raise newException(InvalidSchemaError, "$schema is not a string")
  # A trailing empty fragment does not name another dialect.
  let uri = declared.getStr().strip(leading = false, chars = {'#'})
  for dialect in SchemaDialect:
    if uri == ($dialect).strip(leading = false, chars = {'#'}):
      return dialect
  raise newException(UnsupportedDialectError,
    "unsupported JSON Schema dialect '" & declared.getStr() &
    "'; supported: " & $sdDraft202012 & " and " & $sdDraft07)

type
  Validator = object
    root: JsonNode
    dialect: SchemaDialect
    violations: seq[SchemaViolation]
    regexes: Table[string, Regex]
    limits: SchemaLimits
    depth: int
    checks: int
    regexBudget: int
    refs: seq[tuple[reference: string, depth: int]]
      ## The `$ref`s being followed and how deep in the instance each one was.

func pointer(path: seq[string]): string =
  for part in path:
    result.add '/'
    result.add part.replace("~", "~0").replace("/", "~1")

proc invalid(message: string) {.noreturn.} =
  raise newException(InvalidSchemaError, message)

proc overLimit(message: string) {.noreturn.} =
  raise newException(SchemaLimitError, message)

proc keyword(schema: JsonNode, name: string, kinds: set[JsonNodeKind]): JsonNode =
  ## The value of keyword `name`, or nil; raises when it has the wrong type.
  result = schema{name}
  if not result.isNil and result.kind notin kinds:
    invalid("'" & name & "' has the wrong type")

func isInteger(node: JsonNode): bool =
  node.kind == JInt or (node.kind == JFloat and node.fnum.classify in {fcNormal, fcZero, fcSubnormal} and
                        node.fnum == floor(node.fnum))

func jsonEquals(a, b: JsonNode): bool =
  ## JSON equality, where 1 and 1.0 are the same number.
  if a.kind in {JInt, JFloat} and b.kind in {JInt, JFloat}:
    return a.getFloat() == b.getFloat()
  if a.kind != b.kind:
    return false
  case a.kind
  of JArray:
    if a.len != b.len: return false
    for i in 0 ..< a.len:
      if not jsonEquals(a[i], b[i]): return false
    true
  of JObject:
    if a.len != b.len: return false
    for key, value in a.pairs:
      if not b.hasKey(key) or not jsonEquals(value, b[key]): return false
    true
  else: a == b

func typeName(node: JsonNode): string =
  case node.kind
  of JNull: "null"
  of JBool: "boolean"
  of JInt, JFloat: (if node.isInteger: "integer" else: "number")
  of JString: "string"
  of JArray: "array"
  of JObject: "object"

func matchesType(node: JsonNode, name: string): bool =
  case name
  of "null": node.kind == JNull
  of "boolean": node.kind == JBool
  of "integer": node.kind in {JInt, JFloat} and node.isInteger
  of "number": node.kind in {JInt, JFloat}
  of "string": node.kind == JString
  of "array": node.kind == JArray
  of "object": node.kind == JObject
  else: invalid("'" & name & "' is not a JSON Schema type")

proc resolveRef(v: Validator, reference: string): JsonNode =
  if not reference.startsWith("#"):
    raise newException(UnsupportedKeywordError,
      "$ref '" & reference & "' leaves the document; only local references are supported")
  result = v.root
  if reference == "#":
    return
  if not reference.startsWith("#/"):
    raise newException(UnsupportedKeywordError,
      "$ref '" & reference & "' names an anchor; only JSON Pointers are supported")
  for rawPart in reference[2 .. ^1].split('/'):
    let part = rawPart.replace("%25", "%").replace("~1", "/").replace("~0", "~")
    if result.kind == JObject and result.hasKey(part):
      result = result[part]
    elif result.kind == JArray and part.len > 0 and part.allCharsInSet(Digits) and
         parseInt(part) < result.len:
      result = result[parseInt(part)]
    else:
      invalid("$ref '" & reference & "' points at nothing")

proc check(v: var Validator, schema, instance: JsonNode, path: seq[string])

proc passes(v: var Validator, schema, instance: JsonNode, path: seq[string]): bool =
  ## Whether `instance` satisfies `schema`, recording nothing.
  let before = v.violations.len
  v.check(schema, instance, path)
  result = v.violations.len == before
  v.violations.setLen(before)

proc add(v: var Validator, path: seq[string], message: string) =
  v.violations.add SchemaViolation(path: path.pointer, message: message)

proc regexFor(v: var Validator, pattern: string): Regex =
  if pattern notin v.regexes:
    v.regexes[pattern] =
      try: compileRegex(pattern, v.limits.regex)
      except RegexLimitError as e: overLimit("pattern '" & pattern & "': " & e.msg)
      except RegexError as e: invalid("pattern '" & pattern & "': " & e.msg)
    v.regexBudget -= v.regexes[pattern].size
    if v.regexBudget < 0:
      overLimit("the patterns of the schema are too large to compile within the limit")
  v.regexes[pattern]

proc matches(v: var Validator, pattern, text: string): bool =
  ## Whether `pattern` matches anywhere in `text`.
  let re = v.regexFor(pattern)
  try: re.isMatch(text, v.regexBudget)
  except RegexLimitError as e: overLimit("pattern '" & pattern & "': " & e.msg)

proc checkType(v: var Validator, schema, instance: JsonNode, path: seq[string]) =
  let declared = schema.keyword("type", {JString, JArray})
  if declared.isNil:
    return
  var names: seq[string]
  if declared.kind == JString:
    names.add declared.getStr()
  else:
    for item in declared:
      if item.kind != JString: invalid("'type' has the wrong type")
      names.add item.getStr()
  for name in names:
    if instance.matchesType(name):
      return
  v.add(path, "expected " & names.join(" or ") & " but found " & instance.typeName)

proc checkNumber(v: var Validator, schema, instance: JsonNode, path: seq[string]) =
  let value = instance.getFloat()
  let numbers = {JInt, JFloat}
  var limit = schema.keyword("minimum", numbers)
  if not limit.isNil and value < limit.getFloat():
    v.add(path, $instance & " is below the minimum " & $limit)
  limit = schema.keyword("maximum", numbers)
  if not limit.isNil and value > limit.getFloat():
    v.add(path, $instance & " is above the maximum " & $limit)
  limit = schema.keyword("exclusiveMinimum", numbers)
  if not limit.isNil and value <= limit.getFloat():
    v.add(path, $instance & " is not above the exclusive minimum " & $limit)
  limit = schema.keyword("exclusiveMaximum", numbers)
  if not limit.isNil and value >= limit.getFloat():
    v.add(path, $instance & " is not below the exclusive maximum " & $limit)
  let divisor = schema.keyword("multipleOf", numbers)
  if not divisor.isNil:
    let step = divisor.getFloat()
    if step <= 0: invalid("'multipleOf' must be above zero")
    let quotient = value / step
    if abs(quotient - round(quotient)) > 1e-9 * max(1.0, abs(quotient)):
      v.add(path, $instance & " is not a multiple of " & $divisor)

proc checkString(v: var Validator, schema, instance: JsonNode, path: seq[string]) =
  let text = instance.getStr()
  let numbers = {JInt, JFloat}
  let shortest = schema.keyword("minLength", numbers)
  let longest = schema.keyword("maxLength", numbers)
  if not shortest.isNil or not longest.isNil:
    let length = text.runeLen
    if not shortest.isNil and length < shortest.getInt():
      v.add(path, "shorter than " & $shortest & " characters")
    if not longest.isNil and length > longest.getInt():
      v.add(path, "longer than " & $longest & " characters")
  let pattern = schema.keyword("pattern", {JString})
  if not pattern.isNil and not v.matches(pattern.getStr(), text):
    v.add(path, "does not match the pattern '" & pattern.getStr() & "'")

proc checkArray(v: var Validator, schema, instance: JsonNode, path: seq[string]) =
  let numbers = {JInt, JFloat}
  let items = instance.elems
  var limit = schema.keyword("minItems", numbers)
  if not limit.isNil and items.len < limit.getInt():
    v.add(path, "fewer than " & $limit & " items")
  limit = schema.keyword("maxItems", numbers)
  if not limit.isNil and items.len > limit.getInt():
    v.add(path, "more than " & $limit & " items")
  let unique = schema.keyword("uniqueItems", {JBool})
  if not unique.isNil and unique.getBool():
    for i in 0 ..< items.len:
      for j in i + 1 ..< items.len:
        if jsonEquals(items[i], items[j]):
          v.add(path, "items " & $i & " and " & $j & " are equal")

  # The items after the positional ones; `prefixItems` in 2020-12, an array
  # `items` in draft-07.
  var positional = 0
  var rest: JsonNode
  let itemsKeyword = schema{"items"}
  if v.dialect == sdDraft202012:
    let prefix = schema.keyword("prefixItems", {JArray})
    if not prefix.isNil:
      positional = prefix.len
      for i in 0 ..< min(prefix.len, items.len):
        v.check(prefix[i], items[i], path & $i)
    rest = itemsKeyword
  elif not itemsKeyword.isNil and itemsKeyword.kind == JArray:
    positional = itemsKeyword.len
    for i in 0 ..< min(itemsKeyword.len, items.len):
      v.check(itemsKeyword[i], items[i], path & $i)
    rest = schema{"additionalItems"}
  else:
    rest = itemsKeyword
  if not rest.isNil:
    for i in positional ..< items.len:
      v.check(rest, items[i], path & $i)

  let contains = schema{"contains"}
  if not contains.isNil:
    var matching = 0
    for index, item in items:
      if v.passes(contains, item, path & $index):
        inc matching
    let minContains = schema.keyword("minContains", numbers)
    let maxContains = schema.keyword("maxContains", numbers)
    let least = if minContains.isNil or v.dialect == sdDraft07: 1 else: minContains.getInt()
    if matching < least:
      v.add(path, "fewer than " & $least & " items satisfy 'contains'")
    if not maxContains.isNil and v.dialect != sdDraft07 and matching > maxContains.getInt():
      v.add(path, "more than " & $maxContains & " items satisfy 'contains'")

proc checkObject(v: var Validator, schema, instance: JsonNode, path: seq[string]) =
  let numbers = {JInt, JFloat}
  var limit = schema.keyword("minProperties", numbers)
  if not limit.isNil and instance.len < limit.getInt():
    v.add(path, "fewer than " & $limit & " properties")
  limit = schema.keyword("maxProperties", numbers)
  if not limit.isNil and instance.len > limit.getInt():
    v.add(path, "more than " & $limit & " properties")
  let required = schema.keyword("required", {JArray})
  if not required.isNil:
    for name in required:
      if name.kind != JString: invalid("'required' has the wrong type")
      if not instance.hasKey(name.getStr()):
        v.add(path, "missing required property '" & name.getStr() & "'")

  let properties = schema.keyword("properties", {JObject})
  let patterns = schema.keyword("patternProperties", {JObject})
  let additional = schema{"additionalProperties"}
  for name, value in instance.pairs:
    var covered = false
    if not properties.isNil and properties.hasKey(name):
      covered = true
      v.check(properties[name], value, path & name)
    if not patterns.isNil:
      for pattern, sub in patterns.pairs:
        if v.matches(pattern, name):
          covered = true
          v.check(sub, value, path & name)
    if not covered and not additional.isNil:
      if additional.kind == JBool and not additional.getBool():
        v.add(path & name, "property '" & name & "' is not allowed")
      else:
        v.check(additional, value, path & name)
  let names = schema{"propertyNames"}
  if not names.isNil:
    for name in instance.keys:
      v.check(names, %name, path & name)

  let dependent = schema.keyword("dependentRequired", {JObject})
  if not dependent.isNil:
    for name, needed in dependent.pairs:
      if instance.hasKey(name) and needed.kind == JArray:
        for other in needed:
          if other.kind == JString and not instance.hasKey(other.getStr()):
            v.add(path, "'" & name & "' requires property '" & other.getStr() & "'")
  var dependentSchemas = schema.keyword("dependentSchemas", {JObject})
  if dependentSchemas.isNil and v.dialect == sdDraft07:
    # Draft-07 `dependencies` holds both forms.
    let old = schema.keyword("dependencies", {JObject})
    if not old.isNil:
      for name, dependency in old.pairs:
        if not instance.hasKey(name): continue
        if dependency.kind == JArray:
          for other in dependency:
            if other.kind == JString and not instance.hasKey(other.getStr()):
              v.add(path, "'" & name & "' requires property '" & other.getStr() & "'")
        else:
          v.check(dependency, instance, path)
  if not dependentSchemas.isNil:
    for name, sub in dependentSchemas.pairs:
      if instance.hasKey(name):
        v.check(sub, instance, path)

proc checkCombinators(v: var Validator, schema, instance: JsonNode, path: seq[string]) =
  let all = schema.keyword("allOf", {JArray})
  if not all.isNil:
    for sub in all:
      v.check(sub, instance, path)
  let any = schema.keyword("anyOf", {JArray})
  if not any.isNil:
    var satisfied = false
    for sub in any:
      if v.passes(sub, instance, path):
        satisfied = true
        break
    if not satisfied:
      v.add(path, "satisfies none of the 'anyOf' schemas")
  let one = schema.keyword("oneOf", {JArray})
  if not one.isNil:
    var count = 0
    for sub in one:
      if v.passes(sub, instance, path):
        inc count
    if count != 1:
      v.add(path, "satisfies " & $count & " of the 'oneOf' schemas, not exactly one")
  let negated = schema{"not"}
  if not negated.isNil and v.passes(negated, instance, path):
    v.add(path, "satisfies the 'not' schema")
  let condition = schema{"if"}
  if not condition.isNil:
    if v.passes(condition, instance, path):
      if schema.hasKey("then"): v.check(schema["then"], instance, path)
    elif schema.hasKey("else"):
      v.check(schema["else"], instance, path)

proc checkBody(v: var Validator, schema, instance: JsonNode, path: seq[string]) =
  if schema.kind == JBool:
    if not schema.getBool():
      v.add(path, "no value satisfies the schema 'false'")
    return
  if schema.kind != JObject:
    invalid("a schema is neither an object nor a boolean")
  for name in UnsupportedKeywords:
    if schema.hasKey(name):
      raise newException(UnsupportedKeywordError,
        "the keyword '" & name & "' is not supported")

  let reference = schema.keyword("$ref", {JString})
  if not reference.isNil:
    let target = v.resolveRef(reference.getStr())
    for followed in v.refs:
      if followed.reference == reference.getStr() and followed.depth == path.len:
        invalid("$ref '" & reference.getStr() & "' leads back to itself without " &
                "reading further into the instance")
    v.refs.add (reference.getStr(), path.len)
    v.check(target, instance, path)
    discard v.refs.pop
    if v.dialect == sdDraft07:
      return  # draft-07: siblings of $ref are ignored

  v.checkType(schema, instance, path)
  let enumeration = schema.keyword("enum", {JArray})
  if not enumeration.isNil:
    var found = false
    for candidate in enumeration:
      if jsonEquals(candidate, instance):
        found = true
        break
    if not found:
      v.add(path, $instance & " is not one of the 'enum' values")
  if schema.hasKey("const") and not jsonEquals(schema["const"], instance):
    v.add(path, "differs from the 'const' value " & $schema["const"])

  case instance.kind
  of JInt, JFloat: v.checkNumber(schema, instance, path)
  of JString: v.checkString(schema, instance, path)
  of JArray: v.checkArray(schema, instance, path)
  of JObject: v.checkObject(schema, instance, path)
  else: discard
  v.checkCombinators(schema, instance, path)

proc check(v: var Validator, schema, instance: JsonNode, path: seq[string]) =
  inc v.depth
  inc v.checks
  if v.depth > v.limits.maxDepth:
    overLimit("schemas and instances nest deeper than " & $v.limits.maxDepth & " levels")
  if v.checks > v.limits.maxChecks:
    overLimit("the validation needs more than " & $v.limits.maxChecks & " schema applications")
  v.checkBody(schema, instance, path)
  dec v.depth

proc validate*(schema, instance: JsonNode,
               limits = DefaultSchemaLimits): seq[SchemaViolation] =
  ## What is wrong with `instance` under `schema`; empty when it conforms.
  ## Raises InvalidSchemaError (or a subclass) when the schema cannot be
  ## checked; that includes a `pattern` the regular expression engine rejects.
  ## Raises SchemaLimitError when `limits` are reached.
  var v = Validator(root: schema, dialect: dialectOf(schema), limits: limits,
                    regexBudget: limits.maxRegexSteps)
  v.check(schema, instance, @[])
  v.violations

func describe*(violations: seq[SchemaViolation]): string =
  ## The violations on one line, for an error message.
  var parts: seq[string]
  for violation in violations:
    parts.add (if violation.path.len == 0: "" else: violation.path & ": ") & violation.message
  parts.join("; ")
