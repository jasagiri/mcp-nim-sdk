Feature: Skills over MCP (extension io.modelcontextprotocol/skills)
  As the author of a server that ships instructions for using it, or of a host that loads them
  I want skills published and fetched with the Resources primitive, and checked on arrival
  So that a skill is exactly what the server's entry said, and the SDK never runs it

  Source: modelcontextprotocol/ext-skills at 167da6c0d42c247a8f8470228a10ca711e3f6c45,
  specification/stable/skills.mdx (SEP-2640, Final), base protocol 2026-07-28 or later.
  The extension is not part of the core of any dated version: it is active only
  where a server called registerSkills (or a client declareSkills), and only in
  a build that speaks 2026-07-28.

  @spec:MCP-EXT-SKILLS-1
  Scenario: The YAML frontmatter of a SKILL.md is read into JSON, within a supported subset
    Given a SKILL.md with scalars, quoted strings, block scalars, lists and a nested mapping
    When its frontmatter is read
    Then the fields are a JSON object, and anchors, tags, flow mappings, duplicate keys and tab indentation are refused

  @spec:MCP-EXT-SKILLS-2
  Scenario: A skill name follows the Agent Skills rules
    Given names with uppercase letters, leading, trailing or doubled hyphens, symbols and over 64 characters
    When they are validated
    Then each is refused and ordinary names are accepted

  @spec:MCP-EXT-SKILLS-3
  Scenario: A URI or path that could leave the skill is refused
    Given resource URIs with dot segments, escaped dot segments, backslashes or empty segments
    When they are split or resolved against a skill root
    Then none is accepted

  @spec:MCP-EXT-SKILLS-4
  Scenario: A storage path for a skill file names the server and stays inside the storage root
    Given two servers that serve the same URI
    When the host computes where to keep the file
    Then the paths differ, lie under the root, and a label that climbs out of it is refused

  @spec:MCP-EXT-SKILLS-5
  Scenario: An entry from the network is accepted only if it follows every rule
    Given entries that break one rule each: the name, the path, the manifest, the digest, the size, the limits
    When they are parsed
    Then each is refused with the rule it breaks, and the specification's own entries are accepted
