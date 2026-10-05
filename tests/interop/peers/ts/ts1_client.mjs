// Client on the TypeScript SDK 1.x. Usage: ts1_client.mjs stdio CMD [ARGS...] | http URL | sse URL
// Without MCP_VERSION it offers the installed SDK's LATEST_PROTOCOL_VERSION, so the
// requested version is chosen by the npm directory this file is copied into:
//   sdk 1.10.2 -> 2024-11-05, 1.12.3 -> 2025-03-26, 1.23.1 -> 2025-06-18, 1.32.1 -> 2025-11-25
// MCP_VERSION overrides the offer. 1.x has no option for this, so the outgoing
// initialize request is rewritten on the transport.
// Prints one JSON line (protocolVersion = negotiated version); exit code 0 on success.
import { readFileSync } from 'node:fs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InitializeResultSchema, LATEST_PROTOCOL_VERSION } from '@modelcontextprotocol/sdk/types.js';

const sdkPackage = new URL('./node_modules/@modelcontextprotocol/sdk/package.json', import.meta.url);
const impl = `typescript-sdk-${JSON.parse(readFileSync(sdkPackage, 'utf8')).version}`;
const [kind, ...target] = process.argv.slice(2);
const want = process.env.MCP_VERSION;

const openTransport = async () => {
    if (kind === 'stdio') {
        const { StdioClientTransport } = await import('@modelcontextprotocol/sdk/client/stdio.js');
        return new StdioClientTransport({ command: target[0], args: target.slice(1) });
    }
    if (kind === 'sse') {
        const { SSEClientTransport } = await import('@modelcontextprotocol/sdk/client/sse.js');
        return new SSEClientTransport(new URL(target[0]));
    }
    const { StreamableHTTPClientTransport } = await import('@modelcontextprotocol/sdk/client/streamableHttp.js');
    return new StreamableHTTPClientTransport(new URL(target[0]));
};

let out;
try {
    const client = new Client({ name: 'interop-client-ts1', version: '0.0.1' }, { capabilities: {} });
    const transport = await openTransport();
    const send = transport.send.bind(transport);
    transport.send = (message, opts) => {
        if (want && message.method === 'initialize') message.params.protocolVersion = want;
        return send(message, opts);
    };
    // 1.x keeps no public record of the negotiated version: read it off the initialize result.
    let negotiated;
    const request = client.request.bind(client);
    client.request = async (req, schema, opts) => {
        const result = await request(req, schema, opts);
        if (schema === InitializeResultSchema) negotiated = result.protocolVersion;
        return result;
    };
    await client.connect(transport);
    const tools = await client.listTools();
    const result = await client.callTool({ name: 'echo', arguments: { text: 'hello' } });
    out = {
        ok: !result.isError && result.content[0].text === 'hello',
        impl,
        requested: want ?? LATEST_PROTOCOL_VERSION,
        protocolVersion: negotiated,
        tools: tools.tools.map((t) => t.name),
        result: result.content[0].text
    };
    await client.close();
} catch (e) {
    out = { ok: false, impl, error: `${e.name}: ${e.message}` };
}
console.log(JSON.stringify(out));
process.exit(out.ok ? 0 : 1);
