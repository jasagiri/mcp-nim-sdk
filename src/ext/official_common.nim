## The official extensions this line carries, and the protocol version each
## targets: the one table that their registrations, their tests and their
## documentation agree on, as `protocol/features` is for the core.
##
## An official extension is an add-on to the core. It targets one released
## version and those after it, and every registration of it (on a server or a
## client) goes through `requireTargetSpoken`: a server or client limited to
## an older version refuses it with ValueError naming the extension and its
## target, instead of declaring something its peers cannot use.
## `tests/external/test_ext_targets.nim` checks that statement for every
## extension below, on every build `testAllVersions` makes.
##
## MCP Apps (`ext/apps`) is not in the table: its specification has a host
## declare it in the `initialize` handshake of the earlier versions as well,
## so it targets no version this SDK could refuse.

import ../protocol/version

type
  OfficialExtension* = enum
    officialTasks               ## `ext/tasks`: io.modelcontextprotocol/tasks, ext-tasks @ 5246bc3d
    officialSkills              ## `ext/skills`: io.modelcontextprotocol/skills, ext-skills @ 167da6c0
    officialClientCredentials   ## `ext/auth_client_credentials`:
                                ## io.modelcontextprotocol/oauth-client-credentials, ext-auth @ fb374c7d
    officialEnterpriseManaged   ## `ext/auth_enterprise_managed`:
                                ## io.modelcontextprotocol/enterprise-managed-authorization, ext-auth @ fb374c7d

func targetVersion*(extension: OfficialExtension): McpProtocolVersion {.raises: [].} =
  ## The protocol version `extension` is written against.
  case extension
  of officialTasks, officialSkills, officialClientCredentials, officialEnterpriseManaged:
    # Declared through the `extensions` capability, which exists from 2026-07-28.
    mpv20260728

func displayName*(extension: OfficialExtension): string {.raises: [].} =
  ## What an error message calls `extension`.
  case extension
  of officialTasks: "the Tasks extension"
  of officialSkills: "the Skills extension"
  of officialClientCredentials: "the OAuth client credentials extension"
  of officialEnterpriseManaged: "the enterprise-managed authorization extension"

func requireTargetSpoken*(ceiling: McpProtocolVersion, extension: OfficialExtension) {.raises: [ValueError].} =
  ## Raises ValueError, naming `extension`, its target version and `ceiling`,
  ## unless a server or client limited to `ceiling` speaks the target or a
  ## later version. Every registration of an official extension calls it first.
  requireVersionSpoken(ceiling, extension.targetVersion, extension.displayName)
