## Skills over MCP (`io.modelcontextprotocol/skills`): publish and discover
## Agent Skills with the Resources primitive plus `skills/list` and
## `skills/get`. Not exported by `import mcp`; import it. A server serves
## skills only after `registerSkills`, which declares the extension; a client
## declares nothing (the specification asks only the server to) and uses the
## procs of this module against a server that declared it.
##
## Source: modelcontextprotocol/ext-skills @ 167da6c0d42c247a8f8470228a10ca711e3f6c45,
## specification/stable/skills.mdx (SEP-2640, status Final). Base protocol
## revision 2026-07-28 or later.
##
## What the SDK does: serve a catalog of skills, and fetch and verify the
## skills of a server. What it does not do: run a skill, honor `allowed-tools`
## or any other frontmatter field, ask a user for approval, or cache to disk.
## Those belong to the host; `contentBinding` and `skillStoragePath` are the
## pieces the SDK offers for them.

import ./skills/frontmatter
import ./skills/model
import ./skills/catalog
import ./skills/consumer

export frontmatter, model, catalog, consumer
