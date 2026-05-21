import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const MCP_ENV = {
  AGENTMEMORY_URL: 'http://localhost:3111',
  EMBEDDING_PROVIDER: 'local',
};

function agentmemoryMcpEntry(): { command: string; args: string[]; env: Record<string, string> } {
  return {
    command: 'npx',
    args: ['-y', '@agentmemory/mcp'],
    env: { ...MCP_ENV },
  };
}

async function readJson(filePath: string): Promise<unknown> {
  return fs.readFile(filePath, 'utf8').then(JSON.parse).catch(() => ({}));
}

async function writeJson(filePath: string, data: unknown): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${JSON.stringify(data, null, 2)}\n`, 'utf8');
}

export function antigravityMcpPath(home = os.homedir()): string {
  return path.join(home, '.gemini', 'antigravity', 'mcp_config.json');
}

export async function installAntigravityMcp(filePath = antigravityMcpPath()): Promise<string> {
  const existing = await readJson(filePath);
  const config = existing && typeof existing === 'object' ? { ...(existing as Record<string, unknown>) } : {};
  const servers =
    config.mcpServers && typeof config.mcpServers === 'object'
      ? { ...(config.mcpServers as Record<string, unknown>) }
      : {};
  servers.agentmemory = agentmemoryMcpEntry();
  config.mcpServers = servers;
  await writeJson(filePath, config);
  return filePath;
}

export function codexConfigPath(home = os.homedir()): string {
  return path.join(process.env.CODEX_HOME || path.join(home, '.codex'), 'config.toml');
}

export function renderCodexMcpBlock(): string {
  return `[mcp_servers.agentmemory]
command = "npx"
args = ["-y", "@agentmemory/mcp"]

[mcp_servers.agentmemory.env]
AGENTMEMORY_URL = "${MCP_ENV.AGENTMEMORY_URL}"
EMBEDDING_PROVIDER = "${MCP_ENV.EMBEDDING_PROVIDER}"
`;
}

export async function installCodexMcpFallback(filePath = codexConfigPath()): Promise<string> {
  const current = await fs.readFile(filePath, 'utf8').catch(() => '');
  const withoutOld = current
    .replace(/\n?\[mcp_servers\.agentmemory\][\s\S]*?(?=\n\[|$)/g, '')
    .replace(/\n?\[mcp_servers\.agentmemory\.env\][\s\S]*?(?=\n\[|$)/g, '')
    .trim();
  const next = `${withoutOld ? `${withoutOld}\n\n` : ''}${renderCodexMcpBlock()}`;
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, next, 'utf8');
  return filePath;
}
