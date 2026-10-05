// Echo server on the TypeScript SDK 2.x.
// Usage: ts2_server.mjs stdio | http PORT   [--max=VERSION] [--legacy=reject]
//   (no flag)        dual-era: serveStdio / createMcpHandler pick the era from the opening request
//   --max=VERSION    handshake-only server whose newest version is VERSION (2024-11-05..2025-11-25),
//                    via the public ServerOptions.supportedProtocolVersions; no 2026-07-28 serving
//   --legacy=reject  2026-07-28 only
// Flags are argv, not env: SDK stdio clients do not pass their environment to the child.
// The 2.x server package has no HTTP+SSE (2024-11-05) transport; use ts1_server.mjs for that.
import { createServer } from 'node:http';
import { NodeStreamableHTTPServerTransport, toNodeHandler } from '@modelcontextprotocol/node';
import { McpServer, createMcpHandler } from '@modelcontextprotocol/server';
import { StdioServerTransport, serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod';

const flag = (name) => process.argv.find((a) => a.startsWith(`--${name}=`))?.split('=')[1];
const HANDSHAKE_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const max = flag('max');
const capped = max !== undefined && max < '2026-07-28';
// Newest first: the first entry is what the server counter-offers.
const options = capped ? { supportedProtocolVersions: HANDSHAKE_VERSIONS.filter((v) => v <= max) } : {};

const factory = () => {
    const server = new McpServer({ name: 'interop-echo-ts2', version: '0.0.1' }, options);
    server.registerTool(
        'echo',
        { description: 'Echo back the given text.', inputSchema: z.object({ text: z.string() }) },
        async ({ text }) => ({ content: [{ type: 'text', text }] })
    );
    return server;
};
const onerror = (e) => console.error('[ts2_server]', e.message);
const reject = flag('legacy') === 'reject';

if (process.argv[2] === 'stdio') {
    if (capped) await factory().connect(new StdioServerTransport());
    else serveStdio(factory, { legacy: reject ? 'reject' : 'serve', onerror });
} else {
    const handler = capped
        ? async (req, res) => {
              const transport = new NodeStreamableHTTPServerTransport({ sessionIdGenerator: undefined });
              await factory().connect(transport);
              await transport.handleRequest(req, res);
          }
        : toNodeHandler(createMcpHandler(factory, { legacy: reject ? 'reject' : 'stateless', onerror }));
    createServer(handler).listen(Number(process.argv[3]), '127.0.0.1');
}
