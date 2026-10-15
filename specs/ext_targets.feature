Feature: The protocol version each official extension targets
  As someone building on the official extensions this SDK carries
  I want each extension to say which protocol version it is written against
  So that no build, of any version, offers an extension its peers cannot use

  The official extensions are add-ons to the core. Each states one target
  version (the `OfficialExtension` table of `ext/official_common`, exported
  by every extension's module); Tasks, Skills and the two authorization
  extensions target 2026-07-28, the version with the `extensions`
  capability. MCP Apps is not in the table: its specification has a host
  declare it in the `initialize` handshake of the earlier versions as well.

  @spec:MCP-EXT-TARGET-1
  Scenario: Below its target, every registration of an official extension is refused
    Given an official extension and a server or client limited to a version older than the extension's target
    When any registration of the extension is made on it
    Then ValueError is raised naming the extension, its target version and the version the side speaks up to
    And a build whose default version is older than the target refuses every registration of the extension

  @spec:MCP-EXT-TARGET-2
  Scenario: At or above its target, an official extension registers and answers
    Given an official extension and a server or client limited to its target version or a later one
    When every registration of the extension is made
    Then each is accepted, and a client of a server that registered the extension gets an answer to its first call
