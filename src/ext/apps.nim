## MCP Apps (`io.modelcontextprotocol/ui`): servers deliver interactive UIs
## that a host shows in a sandboxed iframe. An official extension, off unless
## a program imports this module and opts in:
##
## - server: `newAppsRegistry()` for the `ui://` resources, `appToolInfo` for
##   tools that render with one, `degradeForPlainHosts` so only hosts that
##   declared the extension see UI references;
## - host (client): `declareApps()` before connect, `listAppTools`,
##   `fetchUiResource` with limits, `contentSecurityPolicy` for the CSP to enforce;
## - the messages between the host and a View as pure functions over JSON
##   (`apps/messages`), since delivering them is the host application's work.
##
## Based on the stable MCP Apps specification 2026-01-26,
## modelcontextprotocol/ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f.
## Not in this SDK: see docs of each module and specs/ext_apps.feature.

import ./apps/model
import ./apps/messages
import ./apps/provider
import ./apps/host
export model, messages, provider, host
