# Protocol versions

MCP has five dated versions. This build speaks `{{version}}` (its default) and every version before it.

{{version_table}}

## The build default

`mcpDefaultProtocolVersion` in `src/protocol/version.nim` is the newest version a build speaks; the release branch `{{branch}}` differs from the other branches only in that line and in the generated documents. Override it to build the same tree as another version:

```sh
nim c -d:mcpDefaultProtocolVersion=2025-06-18 yourprogram.nim
```

A server or client created with `protocolVersion` outside what the build speaks raises `ValueError`.

{{#if modern}}
## The oldest version

`mcpOldestProtocolVersion` is the oldest version a build speaks; it is `2024-11-05` unless overridden. A build that speaks `2026-07-28` alone knows nothing of the `initialize` handshake, of sessions or of the HTTP+SSE transport:

```sh
nim c -d:mcpOldestProtocolVersion=2026-07-28 yourprogram.nim
```

Such a server answers `initialize` with an error that names the versions it speaks, answers GET and DELETE at its HTTP endpoint with `405`, and ignores `Mcp-Session-Id` and `Last-Event-ID`. The tests run with the oldest version at `2024-11-05` and at `2026-07-28`; values in between compile and are not tested.

A build that speaks earlier versions as well still answers a GET or DELETE that names `2026-07-28` in `MCP-Protocol-Version` with `405`: that version has neither.

{{/if}}

## Two ways of starting

{{#if ftInitializeHandshake}}
Versions before `2026-07-28` start with an `initialize` request: the client offers a version, the server answers with the version it will use, and the client confirms with `notifications/initialized`. A server answers an offer it does not speak with the newest earlier version it does; a client that does not accept that answer gives up.

{{/if}}
{{#if modern}}
From `2026-07-28` there is no handshake. Every request carries its protocol version and the client's capabilities in `_meta`, and a server states what it speaks in the result of `server/discover`. A server that does not know the version of a request answers with an error that lists the versions it speaks.

A client connecting to a server first sends `server/discover`. If the server answers, the client uses the newest version both speak; if it does not answer (the probe times out after `probeTimeoutMs`, 5 seconds by default) or does not know the method, the client sends `initialize` and continues with an earlier version. A server built with this SDK serves both ways at once: a request that carries `_meta` with a protocol version is served the new way, any other the old way.

{{/if}}
{{#if !modern}}
This build does not speak `2026-07-28`: a server answers `server/discover` with "method not found", and a client starts with `initialize`.

{{/if}}
After connecting, `client.negotiatedVersion` is the version in use.

## What changes between versions

The feature table of each version is in the [README](../README.md). Behaviour that depends on the version is decided by asking the table (`version.has(ftXxx)` in `src/protocol/features.nim`), not by comparing dates.

## Where the tags and branches used to point

Until 2026-10 the tag `mcp-<version>` marked the commit that first mentioned a version and the branch of the same name held the code of all versions with another default; neither gave an SDK that spoke just that version. Both now name the same commit: the common code plus the one line that sets the default, and the documents generated for it. Anything pinned to the earlier commits can still reach them by id:

| Name | Tag was | Branch was |
|---|---|---|
| `mcp-2024-11-05` | `e5d015a272d004f2622872a9c03d9ba2b126f8a1` | `dc1bad0c1d5ded98045157e1500ea2d8e2a89c88` |
| `mcp-2025-03-26` | `e5d015a272d004f2622872a9c03d9ba2b126f8a1` | `584e25df1917fbe82434b7a5916b180c0ba14299` |
| `mcp-2025-06-18` | `89006de90e1bd37b8c90ce91ca8ad62194af047d` | `5b8c20e3650642e2f2b5988d8203c56049aa02a1` |
| `mcp-2025-11-25` | `b513423a4c772f65603220bb2f045fc894de2639` | `e81d24c1e7d9458658001eed892c61aadab69288` |
