# Protocol versions

MCP has five dated versions. This build speaks `{{version}}` (its default) and every version before it.

{{version_table}}

## The build default

`mcpDefaultProtocolVersion` in `src/protocol/version.nim` is the newest version a build speaks; the release branch `{{branch}}` differs from the other branches only in that line and in the generated documents. Override it to build the same tree as another version:

```sh
nim c -d:mcpDefaultProtocolVersion=2025-06-18 yourprogram.nim
```

A server or client created with `protocolVersion` newer than the default raises `ValueError`.

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
