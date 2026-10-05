# MCP Nim SDK {{version}}

This tree speaks MCP `{{version}}` and earlier ({{spoken_versions}}).

- [Protocol versions](versions.md): how a client and a server choose a version, and what the build default means.
{{#if ftStreamableHttp}}
- [Transports](transports.md): stdio and Streamable HTTP.
{{/if}}
{{#if !ftStreamableHttp}}
- [Transports](transports.md): stdio.
{{/if}}
- [Features](features.md): how to use what is implemented.
- [Quality records](quality/): interoperability results and mutation-testing notes.

The feature list with the status of each is in the [README](../README.md).
