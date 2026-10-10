## The rules of the skills extension that need no connection: reading
## frontmatter, names, URIs and paths, and entries received from a server.
## The digests and sizes are the ones the specification's own example
## publishes (ext-skills@167da6c, skills.mdx, "Example Message Flow").

import std/[algorithm, json, options, os, strutils, unittest]
import ext/skills
import ./ext_skills_fixtures

proc specEntry(): JsonNode =
  %*{
    "uri": "skill://pdf-processing/SKILL.md",
    "frontmatter": {"name": "pdf-processing",
                    "description": "Extract, fill, and assemble PDF documents"},
    "resources": [
      {"uri": "skill://pdf-processing/SKILL.md",
       "digest": "sha256:99b737495721155ece826d57521e2d66141ebdc1344a400487481ea2642ab19e",
       "size": 151},
      {"uri": "skill://pdf-processing/templates/invoice.md",
       "digest": "sha256:61f4ea6d2c75fde1b4977219e7e3107d491c3c26aefb6686e84d6281c088d9ee",
       "size": 29}]}

suite "frontmatter":

  test "Given a SKILL.md with scalars, quotes, block scalars, lists and a mapping, when its frontmatter is read, then the fields are JSON":
    let text = "---\nname: pdf-processing\n# a comment\ndescription: \"Extract, fill: and assemble\"\nlicense: 'It''s Apache-2.0'\n" &
      "compatibility: needs network   # trailing comment\nmetadata:\n  author: example-org\n  version: \"1.0\"\n" &
      "tags: [a, 'b c', 3]\nwords:\n  - x\n  - y\nnotes: |\n  line one\n    indented\n  line two\nfolded: >-\n  one\n  two\n" &
      "count: 3\nratio: 0.5\nflag: true\nnothing:\nlong: starts here\n  and goes on\n---\n\n# Body\n"
    let read = parseFrontmatter(text)
    check read.fields["name"].getStr() == "pdf-processing"
    check read.fields["description"].getStr() == "Extract, fill: and assemble"
    check read.fields["license"].getStr() == "It's Apache-2.0"
    check read.fields["compatibility"].getStr() == "needs network"
    check read.fields["metadata"] == %*{"author": "example-org", "version": "1.0"}
    check read.fields["tags"] == %*["a", "b c", 3]
    check read.fields["words"] == %*["x", "y"]
    check read.fields["notes"].getStr() == "line one\n  indented\nline two\n"
    check read.fields["folded"].getStr() == "one two"
    check read.fields["count"].getInt() == 3
    check read.fields["ratio"].getFloat() == 0.5
    check read.fields["flag"].getBool()
    check read.fields["nothing"].kind == JNull
    check read.fields["long"].getStr() == "starts here and goes on"
    check read.body.strip() == "# Body"

  test "Given the specification's SKILL.md, when read, then name and description come out":
    let read = parseFrontmatter(SkillMd)
    check read.fields == %*{"name": "pdf-processing",
      "description": "Extract, fill, and assemble PDF documents"}
    check "Choose the matching template" in read.body

  test "Given text outside the supported subset, when read, then FrontmatterError is raised":
    for bad in [
      "no fence\nname: x\n",
      "---\nname: x\n",
      "---\nname: &anchor x\n---\n",
      "---\nname: *alias\n---\n",
      "---\nname: !tag x\n---\n",
      "---\nname: {a: 1}\n---\n",
      "---\nname: x\nname: y\n---\n",
      "---\n\tname: x\n---\n",
      "---\n- a\n- b\n---\n",
      "---\nname: \"unterminated\n---\n",
      "---\nlist:\n  - a: b\n---\n",
      "---\nname: x\n  stray: y\n  other\n---\n"]:
      checkpoint bad
      expect FrontmatterError:
        discard parseFrontmatter(bad)

  test "Given a frontmatter that is empty, when read, then there are no fields":
    check parseFrontmatter("---\n---\nbody").fields.len == 0

suite "skill names":

  test "Given ordinary names, when validated, then they are accepted":
    for name in ["pdf-processing", "a", "x1-y2", "refunds", "データ"]:
      checkpoint name
      check validateSkillName(name).isNone

  test "Given names that break the Agent Skills rules, when validated, then each is refused":
    for name in ["", "PDF", "-pdf", "pdf-", "pdf--x", "pdf_x", "pdf x", "a/b", "a.b",
                 "x".repeat(65)]:
      checkpoint name
      check validateSkillName(name).isSome
    check validateSkillName("x".repeat(64)).isNone

  test "Given descriptions of 0, 1 and 1025 characters, when validated, then only the middle one is accepted":
    check validateDescription("").isSome
    check validateDescription("x").isNone
    check validateDescription("x".repeat(1024)).isNone
    check validateDescription("x".repeat(1025)).isSome

suite "URIs and paths":

  test "Given URIs that could leave the skill, when split, then none is accepted":
    for uri in ["skill://a/../b/SKILL.md", "skill://a/./b", "skill://a//b", "skill://a/b/",
                "skill://a\\b", "skill://a/%2e%2e/b", "skill://a/%2E./b", "skill://a/b%2fc",
                "skill://a/b%5cc", "skill://a/b%00", "skill://", "skill:/a", "a/b",
                "skill://a/b?x", "skill://a/b#x", "1skill://a"]:
      checkpoint uri
      check splitResourceUri(uri).isNone

  test "Given ordinary URIs, when split, then the scheme and path come out":
    check splitResourceUri("skill://acme/billing/refunds/SKILL.md").get ==
      (scheme: "skill", path: "acme/billing/refunds/SKILL.md")
    check splitResourceUri("github://owner/repo/skills/x/SKILL.md").isSome

  test "Given a SKILL.md URI, when its root is taken, then the suffix goes and a bad URI has none":
    check skillRootOf("skill://acme/billing/refunds/SKILL.md").get == "skill://acme/billing/refunds"
    check skillRootOf("skill://git-workflow/SKILL.md").get == "skill://git-workflow"
    check skillRootOf("skill://git-workflow/README.md").isNone
    check skillRootOf("skill://a/../SKILL.md").isNone

  test "Given a skill root, when a file URI is resolved against it, then only files strictly inside resolve":
    let root = "skill://pdf-processing"
    check relativePathIn(root, "skill://pdf-processing/templates/invoice.md").get ==
      "templates/invoice.md"
    for uri in ["skill://pdf-processing", "skill://pdf-processing/", "skill://pdf-processingX/a",
                "skill://other/a", "skill://pdf-processing/../x/a",
                "skill://pdf-processing/a/%2e%2e/b", "skill://pdf-processing/a//b"]:
      checkpoint uri
      check relativePathIn(root, uri).isNone

  test "Given file paths a server names inside a skill, when checked, then absolute and climbing paths are refused":
    check safeFilePath("references/GUIDE.md")
    for path in ["", "/etc/passwd", "../x", "a/../x", "a//b", "a/", "a\\b"]:
      checkpoint path
      check not safeFilePath(path)

  test "Given the same URI from two servers, when storage paths are computed, then they differ and stay under the root":
    let root = getTempDir() / "skills-store"
    let a = skillStoragePath(root, "server-a", "skill://pdf/SKILL.md")
    let b = skillStoragePath(root, "server-b", "skill://pdf/SKILL.md")
    check a != b
    check a.startsWith(normalizedPath(root) & DirSep)
    check "server-a" in a and "pdf" in a and "SKILL.md" in a

  test "Given a label or URI that climbs out of the root, when a storage path is computed, then SkillsError is raised":
    let root = getTempDir() / "skills-store"
    for label in ["", ".", ".."]:
      checkpoint label
      expect SkillsError:
        discard skillStoragePath(root, label, "skill://pdf/SKILL.md")
    expect SkillsError:
      discard skillStoragePath(root, "s", "skill://a/../../SKILL.md")
    # A label with a separator is one directory name, not two.
    let odd = skillStoragePath(root, "a/b", "skill://pdf/SKILL.md")
    check odd.startsWith(normalizedPath(root) & DirSep)
    check not odd[normalizedPath(root).len + 1 .. ^1].startsWith("a" & DirSep)

suite "entries from the network":

  test "Given the specification's entry, when parsed, then it is accepted and round-trips":
    let entry = parseSkillEntry(specEntry(), "test")
    check entry.skillName == "pdf-processing"
    check entry.resources.len == 2
    check not entry.dynamic
    check entry.toJson() == specEntry()

  test "Given an entry whose resources is dynamic, when parsed, then it is dynamic and has no files":
    var node = specEntry()
    node["resources"] = %"dynamic"
    let entry = parseSkillEntry(node, "test")
    check entry.dynamic and entry.resources.len == 0
    check entry.toJson()["resources"].getStr() == "dynamic"

  test "Given entries that break one rule each, when parsed, then each raises SkillsError":
    proc broken(change: proc(node: JsonNode)): JsonNode =
      result = specEntry()
      change(result)
    let cases = {
      "no uri": broken(proc(n: JsonNode) = n.delete("uri")),
      "uri without SKILL.md": broken(proc(n: JsonNode) = n["uri"] = %"skill://pdf-processing/README.md"),
      "uri with dot segments": broken(proc(n: JsonNode) = n["uri"] = %"skill://a/../pdf-processing/SKILL.md"),
      "no frontmatter": broken(proc(n: JsonNode) = n.delete("frontmatter")),
      "no description": broken(proc(n: JsonNode) = n["frontmatter"].delete("description")),
      "name not a string": broken(proc(n: JsonNode) = n["frontmatter"]["name"] = %3),
      "name breaks the rules": broken(proc(n: JsonNode) =
        n["uri"] = %"skill://PDF/SKILL.md"; n["frontmatter"]["name"] = %"PDF"),
      "name differs from the path": broken(proc(n: JsonNode) = n["frontmatter"]["name"] = %"other"),
      "no resources": broken(proc(n: JsonNode) = n.delete("resources")),
      "resources is another string": broken(proc(n: JsonNode) = n["resources"] = %"lazy"),
      "resources is a number": broken(proc(n: JsonNode) = n["resources"] = %1),
      "SKILL.md not listed": broken(proc(n: JsonNode) = n["resources"].elems.delete(0)),
      "file outside the skill": broken(proc(n: JsonNode) =
        n["resources"][1]["uri"] = %"skill://other/a.md"),
      "file climbing out": broken(proc(n: JsonNode) =
        n["resources"][1]["uri"] = %"skill://pdf-processing/../x.md"),
      "file listed twice": broken(proc(n: JsonNode) = n["resources"].add n["resources"][1]),
      "digest without prefix": broken(proc(n: JsonNode) =
        n["resources"][1]["digest"] = %"61f4ea6d2c75fde1b4977219e7e3107d491c3c26aefb6686e84d6281c088d9ee"),
      "digest in uppercase": broken(proc(n: JsonNode) =
        n["resources"][1]["digest"] = %("sha256:" & "A".repeat(64))),
      "digest too short": broken(proc(n: JsonNode) = n["resources"][1]["digest"] = %"sha256:abc"),
      "no size": broken(proc(n: JsonNode) = n["resources"][1].delete("size")),
      "negative size": broken(proc(n: JsonNode) = n["resources"][1]["size"] = %(-1)),
      "size is text": broken(proc(n: JsonNode) = n["resources"][1]["size"] = %"29"),
      "over 16 MiB": broken(proc(n: JsonNode) = n["resources"][1]["size"] = %MaxSkillBytes),
      "over 512 files": broken(proc(n: JsonNode) =
        for i in 0 ..< MaxResourcesPerSkill:
          n["resources"].add %*{"uri": "skill://pdf-processing/f" & $i, "size": 1,
            "digest": "sha256:" & "0".repeat(64)})}
    for (label, node) in cases:
      checkpoint label
      expect SkillsError:
        discard parseSkillEntry(node, "test")

  test "Given the limits exactly, when an entry is parsed, then it is accepted":
    var node = specEntry()
    node["resources"][0]["size"] = %1
    node["resources"][1]["size"] = %(MaxSkillBytes - 1)
    check parseSkillEntry(node, "test").resources.len == 2
    var many = specEntry()
    for i in 0 ..< MaxResourcesPerSkill - 2:
      many["resources"].add %*{"uri": "skill://pdf-processing/f" & $i, "size": 1,
        "digest": "sha256:" & "0".repeat(64)}
    check parseSkillEntry(many, "test").resources.len == MaxResourcesPerSkill

  test "Given the files of the specification's example, when digested, then the digests match the published ones":
    check digestOf(SkillMd) == "sha256:99b737495721155ece826d57521e2d66141ebdc1344a400487481ea2642ab19e"
    check digestOf(Invoice) == "sha256:61f4ea6d2c75fde1b4977219e7e3107d491c3c26aefb6686e84d6281c088d9ee"
    check digestOf(PurchaseOrder) == "sha256:f2ff774b1737ff3dec81c47946f9976f18a1a9f69dda0a81f22eabd95173c158"
    check SkillMd.len == 151 and Invoice.len == 29 and PurchaseOrder.len == 35

  test "Given entries with the same files in another order or another digest, when bound, then the binding follows the set":
    let a = parseSkillEntry(specEntry(), "test")
    var reordered = specEntry()
    reordered["resources"].elems.reverse()
    check contentBinding(parseSkillEntry(reordered, "test")) == contentBinding(a)
    var rotated = specEntry()
    rotated["resources"][1]["digest"] = %("sha256:" & "1".repeat(64))
    check contentBinding(parseSkillEntry(rotated, "test")) != contentBinding(a)
    var added = specEntry()
    added["resources"].add %*{"uri": "skill://pdf-processing/new.md", "size": 1,
                              "digest": "sha256:" & "2".repeat(64)}
    check contentBinding(parseSkillEntry(added, "test")) != contentBinding(a)
    var dynamic = specEntry()
    dynamic["resources"] = %"dynamic"
    check contentBinding(parseSkillEntry(dynamic, "test")) == ""

suite "model rules sharpened by the mutation run (g2x-skills-rest)":

  test "Given a name with a character that is neither ASCII nor a letter, when validated, then it is refused":
    for name in ["a€b", "a b", "a😀b"]:
      checkpoint name
      check validateSkillName(name).isSome

  test "Given schemes with digits, plus, hyphen and dot, when a URI is split, then the scheme is accepted":
    for scheme in ["s3", "git+ssh", "a.b-c", "x1"]:
      checkpoint scheme
      check splitResourceUri(scheme & "://host/a/b").get.scheme == scheme

  test "Given segments with a space, a percent escape of a plain character and a control character, when a URI is split, then only the control character and the escaped dot are refused":
    check splitResourceUri("skill://a/my file.md").isSome
    check splitResourceUri("skill://a/b%20c").isSome
    check splitResourceUri("skill://a/%2e/b").isNone
    check splitResourceUri("skill://a/b\x1fc").isNone
    check splitResourceUri("skill://a/b\x7fc").isNone

  test "Given a label and a path segment with a space, when a storage path is computed, then each is percent-encoded with %20":
    let root = getTempDir() / "skills-store"
    check skillStoragePath(root, "my server", "skill://a/my file.md") ==
      normalizedPath(root) / "my%20server" / "skill" / "a" / "my%20file.md"

  test "Given nothing or a value that is not an object, when an entry is parsed, then SkillsError names the rule":
    expect SkillsError:
      discard parseSkillEntry(nil, "test")
    try:
      discard parseSkillEntry(%"text", "test")
      fail()
    except SkillsError as e:
      check "not an object" in e.msg

  test "Given resources that lack a string uri or digest, when an entry is parsed, then the error says what a resource needs":
    let cases = {
      "no uri": proc(n: JsonNode) = n["resources"][1].delete("uri"),
      "uri is a number": proc(n: JsonNode) = n["resources"][1]["uri"] = %5,
      "no digest": proc(n: JsonNode) = n["resources"][1].delete("digest"),
      "digest is a number": proc(n: JsonNode) = n["resources"][1]["digest"] = %5}
    for (label, change) in cases:
      checkpoint label
      let node = specEntry()
      change(node)
      try:
        discard parseSkillEntry(node, "test")
        fail()
      except SkillsError as e:
        check "a resource needs" in e.msg

  test "Given a file of size 0, when an entry is parsed, then it is accepted":
    let node = specEntry()
    node["resources"].add %*{"uri": "skill://pdf-processing/empty.md", "size": 0,
                             "digest": digestOf("")}
    check parseSkillEntry(node, "test").resources.len == 3
