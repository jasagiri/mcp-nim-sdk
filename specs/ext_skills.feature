Feature: Skills over MCP (extension io.modelcontextprotocol/skills)
  As the author of a server that ships instructions for using it, or of a host that loads them
  I want skills published and fetched with the Resources primitive, and checked on arrival
  So that a skill is exactly what the server's entry said, and the SDK never runs it

  Source: modelcontextprotocol/ext-skills at 167da6c0d42c247a8f8470228a10ca711e3f6c45,
  specification/stable/skills.mdx (SEP-2640, Final), base protocol 2026-07-28 or later.
  The extension is not part of the core of any dated version: it is active only
  where a server called registerSkills, and only in
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

  @spec:MCP-EXT-SKILLS-6
  Scenario: Nothing is served until the extension is registered
    Given a server with a catalog that was not registered
    When a client asks for skills/list or reads a skill file
    Then the method is unknown, the file is not found, and the capabilities do not mention the extension

  @spec:MCP-EXT-SKILLS-7
  Scenario: Registering declares the extension, its settings and the resources capability
    Given a server with a catalog
    When registerSkills is called with and without directoryRead
    Then server/discover lists io.modelcontextprotocol/skills with the settings, resources is declared, and a legacy handshake does not mention extensions

  @spec:MCP-EXT-SKILLS-8
  Scenario: Registering is refused where the extension cannot work
    Given a server that speaks no 2026-07-28, or one that already registered skills
    When registerSkills is called
    Then ValueError is raised

  @spec:MCP-EXT-SKILLS-9
  Scenario: skills/list returns complete manifests with digests and cache fields
    Given the skills of the specification's example
    When a client that declared the extension lists them
    Then each entry carries the frontmatter and every file with its sha256 digest and size, and the result has resultType complete, ttlMs and cacheScope

  @spec:MCP-EXT-SKILLS-10
  Scenario: skills/list pages like the base list methods
    Given a catalog of several skills and a page size
    When the client follows nextCursor
    Then every skill arrives once, and a cursor the server did not issue is invalid params

  @spec:MCP-EXT-SKILLS-11
  Scenario: skills/get returns one entry and refuses what is not a skill
    Given a served skill
    When skills/get names its SKILL.md, another file of it, an unknown URI or no string
    Then the first is the entry and the others are -32602

  @spec:MCP-EXT-SKILLS-12
  Scenario: A skill file is an ordinary resource for every client
    Given a served skill with a text file and a binary file
    When any client reads them, and a URI that is not a skill
    Then text comes back as text, binary as base64 blob, and the other URI goes to the server's own handler

  @spec:MCP-EXT-SKILLS-13
  Scenario: The skills methods are served to a client that declared nothing
    Given a registered server
    When a client that did not declare the extension asks skills/list, skills/get or resources/directory/read
    Then it is served: the specification has the server declare the extension and asks nothing of the client
    And a client lists skills only of a server that declared the extension

  @spec:MCP-EXT-SKILLS-14
  Scenario: resources/directory/read lists direct children when directoryRead is declared
    Given a server registered with directoryRead
    When a client reads a skill root, a subdirectory, a file and an unknown URI
    Then directories carry inode/directory, files their metadata, and the last two are -32602; without directoryRead the method is unknown

  @spec:MCP-EXT-SKILLS-15
  Scenario: A skill whose content is generated says dynamic
    Given a skill added with a file provider
    When the client lists it and reads its files
    Then the entry's resources is the string dynamic and the files are what the provider returns now

  @spec:MCP-EXT-SKILLS-16
  Scenario: A skill nested in another is listed on its own and as part of the enclosing one
    Given skills at acme/billing and acme/billing/refunds
    When the client lists them
    Then the enclosing skill's resources include the nested skill's files

  @spec:MCP-EXT-SKILLS-17
  Scenario: A skill the server cannot serve correctly is refused when it is added
    Given a skill with a frontmatter that does not name it, no SKILL.md, an unsafe path, a duplicate or too many files
    When it is added to the catalog
    Then SkillsError is raised

  @spec:MCP-EXT-SKILLS-18
  Scenario: A skill kept in a directory is served, and a symbolic link is refused
    Given a directory with SKILL.md and a subdirectory
    When it is added with addSkillDirectory
    Then its files are served, and a directory with a symbolic link is refused

  @spec:MCP-EXT-SKILLS-19
  Scenario: The client lists skills and reports the entries it must not load
    Given a server whose listing holds a valid entry and an invalid one
    When the client lists the skills
    Then the valid entry is returned and the invalid one is reported with its reason

  @spec:MCP-EXT-SKILLS-20
  Scenario: Fetched content is verified against the held entry
    Given an opened skill
    When the content has a wrong digest or size, the frontmatter differs, or the file is not listed
    Then SkillVerificationError is raised and no content is returned

  @spec:MCP-EXT-SKILLS-21
  Scenario: A skill with generated content is refused unless the host allows it
    Given an entry whose resources is dynamic
    When the host reads it without allowing dynamic skills, and with
    Then the first raises and sends nothing, and the second reads the file

  @spec:MCP-EXT-SKILLS-22
  Scenario: A directory read needs the server's directoryRead and does not extend the manifest
    Given a server without directoryRead, and one with it that lists a file the entry does not
    When the client lists a directory
    Then the first raises with nothing sent, and listedIn leaves out the unlisted file

  @spec:MCP-EXT-SKILLS-23
  Scenario: A changed skill is noticed when its entry is fetched again
    Given an approval bound to an entry
    When skills/get returns a different set of files
    Then the binding differs and refreshEntry says changed

  @spec:MCP-EXT-SKILLS-24
  Scenario: The SDK's server and client agree on the wire
    Given a server that registered skills and a client that declared them, over one transport
    When the client lists, gets, loads a skill and lists a directory
    Then every step succeeds and the loaded instructions are the served ones

  @spec:MCP-EXT-SKILLS-25
  Scenario: Blank lines inside a multi-line value keep their line breaks
    Given a plain scalar that continues on deeper lines, or a folded block, with blank lines inside
    When its frontmatter is read
    Then a line break is a space and n blank lines are n newlines; blank lines after the value add nothing

  @spec:MCP-EXT-SKILLS-26
  Scenario: A trailing comma in a flow sequence adds no item
    Given a flow sequence written as [a, ]
    When its frontmatter is read
    Then the array has the one item

  @spec:MCP-EXT-SKILLS-27
  Scenario: A keep-chomped block scalar with no lines is empty
    Given a block scalar with the + indicator and no lines
    When its frontmatter is read
    Then the value is the empty string, and each blank line adds one newline

  @spec:MCP-EXT-SKILLS-28
  Scenario: A doubled quote in a single-quoted key is one quote
    Given a key written as 'it''s'
    When its frontmatter is read
    Then the key is it's

  @spec:MCP-EXT-SKILLS-29
  Scenario: A hash line inside a block scalar is content
    Given a block scalar with a line that starts with # at the indent of its content
    When its frontmatter is read
    Then the line is part of the value, while a comment outside the block is still a comment

  @spec:MCP-EXT-SKILLS-30
  Scenario: An item missing before a comma in a flow sequence is refused
    Given flow sequences written as [a,,], [,] and [,a]
    When their frontmatter is read
    Then each is refused with FrontmatterError, while [a, ] and [] are read
