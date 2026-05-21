export type ClientName = 'antigravity' | 'codex' | 'claude-code';

export function expandClients(client: string): ClientName[] {
  if (client === 'all') return ['antigravity', 'codex', 'claude-code'];
  if (client === 'antigravity' || client === 'codex' || client === 'claude-code') {
    return [client];
  }
  throw new Error(`Unsupported client: ${client}`);
}
