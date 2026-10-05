// Echo server on the TypeScript SDK 1.x (@modelcontextprotocol/sdk).
// Usage: ts1_server.mjs stdio | http PORT | sse PORT
// Handshake era only. 1.x has no option to cap the version; the ceiling is the
// installed SDK's LATEST_PROTOCOL_VERSION, so it is chosen by the npm directory
// this file is copied into:
//   sdk 1.10.2 -> 2024-11-05, 1.12.3 -> 2025-03-26, 1.23.1 -> 2025-06-18, 1.32.1 -> 2025-11-25
// http is stateless Streamable HTTP; sse is the 2024-11-05 HTTP+SSE transport
// (GET /sse opens the stream, POST /messages?sessionId=... sends).
import { createServer } from 'node:http';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import * as z from 'zod';

const build = () => {
    const server = new McpServer({ name: 'interop-echo-ts1', version: '0.0.1' });
    // tool() exists in every 1.x release; registerTool() only in later ones.
    server.tool('echo', 'Echo back the given text.', { text: z.string() }, async ({ text }) => ({
        content: [{ type: 'text', text }]
    }));
    return server;
};
const [mode, port] = process.argv.slice(2);

if (mode === 'stdio') {
    const { StdioServerTransport } = await import('@modelcontextprotocol/sdk/server/stdio.js');
    await build().connect(new StdioServerTransport());
} else if (mode === 'sse') {
    const { SSEServerTransport } = await import('@modelcontextprotocol/sdk/server/sse.js');
    const sessions = new Map();
    createServer(async (req, res) => {
        const url = new URL(req.url, 'http://127.0.0.1');
        if (req.method === 'GET' && url.pathname === '/sse') {
            const transport = new SSEServerTransport('/messages', res);
            sessions.set(transport.sessionId, transport);
            res.on('close', () => sessions.delete(transport.sessionId));
            await build().connect(transport);
        } else if (req.method === 'POST' && url.pathname === '/messages') {
            const transport = sessions.get(url.searchParams.get('sessionId'));
            if (transport) await transport.handlePostMessage(req, res);
            else res.writeHead(404).end('unknown session');
        } else {
            res.writeHead(404).end();
        }
    }).listen(Number(port), '127.0.0.1');
} else {
    const { StreamableHTTPServerTransport } = await import('@modelcontextprotocol/sdk/server/streamableHttp.js');
    createServer(async (req, res) => {
        const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
        await build().connect(transport);
        await transport.handleRequest(req, res);
    }).listen(Number(port), '127.0.0.1');
}
