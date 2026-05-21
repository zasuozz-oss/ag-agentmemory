import { expandClients } from './clients.js';
import { upsertAgentmemoryEnv } from './env-file.js';
import { installAntigravityMcp, installCodexMcpFallback } from './mcp-config.js';
import { installAntigravityInstructions } from './instructions.js';
import { installAntigravitySkills } from './skills.js';
import { syncAgentmemorySource } from './source-sync.js';
import { connectClaudeCode, installCodexPlugin } from './upstream.js';

export async function runSetup(options: { client: string; syncUpstream?: boolean }): Promise<{ messages: string[] }> {
  const clients = expandClients(options.client);
  const messages: string[] = [];

  if (options.syncUpstream !== false) {
    const source = await syncAgentmemorySource();
    messages.push(`upstream source: ${source.action} ${source.workingPath} (${source.message})`);
  }

  const envPath = await upsertAgentmemoryEnv();
  messages.push(`env: ${envPath}`);

  if (clients.includes('antigravity')) {
    messages.push(`antigravity MCP: ${await installAntigravityMcp()}`);
    messages.push(`antigravity instructions: ${await installAntigravityInstructions()}`);
    messages.push(`antigravity skills: ${await installAntigravitySkills()}`);
  }

  if (clients.includes('codex')) {
    const plugin = await installCodexPlugin();
    if (plugin.ok) {
      messages.push('codex plugin: installed via upstream marketplace');
    } else {
      for (const result of plugin.results) {
        messages.push(`codex plugin: ${result.command}: ${result.ok ? 'ok' : `failed (${result.message})`}`);
      }
      messages.push(`codex MCP fallback: ${await installCodexMcpFallback()}`);
    }
  }

  if (clients.includes('claude-code')) {
    const claude = await connectClaudeCode();
    if (claude.ok) {
      messages.push('claude-code: connected via agentmemory connect claude-code');
    } else if (claude.attempted && claude.result) {
      messages.push(`claude-code: ${claude.result.command}: failed (${claude.result.message})`);
      messages.push(`claude-code manual: ${claude.manualCommands.join(' && ')}`);
    } else {
      messages.push('claude-code: agentmemory command not found');
      messages.push(`claude-code manual: ${claude.manualCommands.join(' && ')}`);
    }
  }

  return { messages };
}
