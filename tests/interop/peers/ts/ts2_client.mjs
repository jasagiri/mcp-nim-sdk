// Client on the TypeScript SDK 2.x. Usage: ts2_client.mjs stdio CMD [ARGS...] | http URL | sse URL
// MCP_VERSION selects what is requested (all through public ClientOptions):
//   unset               -> SDK default (mode 'legacy', offers 2025-11-25)
//   "auto"              -> probe server/discover, fall back to initialize
//   "2026-07-28"        -> versionNegotiation pin (no fallback)
//   a handshake version -> supportedProtocolVersions: [that version]
// Prints one JSON line (protocolVersion = negotiated version); exit code 0 on success.
import { Client, SSEClientTransport, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const [kind, ...target] = process.argv.slice(2);
const want = process.env.MCP_VERSION;
const options =
    want === undefined ? {}
    : want === 'auto' ? { versionNegotiation: { mode: 'auto' } }
    : want >= '2026-07-28' ? { versionNegotiation: { mode: { pin: want } } }
    : { supportedProtocolVersions: [want] };

let out;
try {
    const client = new Client({ name: 'interop-client-ts2', version: '0.0.1' }, options);
    const transport =
        kind === 'stdio' ? new StdioClientTransport({ command: target[0], args: target.slice(1) })
        : kind === 'sse' ? new SSEClientTransport(new URL(target[0]))
        : new StreamableHTTPClientTransport(new URL(target[0]));
    await client.connect(transport);
    const tools = await client.listTools();
    const result = await client.callTool({ name: 'echo', arguments: { text: 'hello' } });
    out = {
        ok: !result.isError && result.content[0].text === 'hello',
        impl: 'typescript-sdk-2.x',
        requested: want ?? 'default',
        protocolVersion: client.getNegotiatedProtocolVersion(),
        tools: tools.tools.map((t) => t.name),
        result: result.content[0].text
    };
    await client.close();
} catch (e) {
    out = { ok: false, impl: 'typescript-sdk-2.x', error: `${e.name}: ${e.message}` };
}
console.log(JSON.stringify(out));
process.exit(out.ok ? 0 : 1);
