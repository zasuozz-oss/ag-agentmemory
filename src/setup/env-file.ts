import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

export const AGENTMEMORY_ENV_VALUES: Record<string, string> = {
  EMBEDDING_PROVIDER: 'local',
  BM25_WEIGHT: '0.4',
  VECTOR_WEIGHT: '0.6',
  AGENTMEMORY_URL: 'http://localhost:3111',
};

export function agentmemoryEnvPath(home = os.homedir()): string {
  return path.join(home, '.agentmemory', '.env');
}

export async function upsertAgentmemoryEnv(filePath = agentmemoryEnvPath()): Promise<string> {
  const current = await fs.readFile(filePath, 'utf8').catch(() => '');
  const lines = current ? current.split(/\r?\n/) : [];
  const seen = new Set<string>();
  const next = lines.map((line) => {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=/);
    if (!match) return line;
    const key = match[1]!;
    if (!(key in AGENTMEMORY_ENV_VALUES)) return line;
    seen.add(key);
    return `${key}=${AGENTMEMORY_ENV_VALUES[key]}`;
  });

  const missing = Object.entries(AGENTMEMORY_ENV_VALUES)
    .filter(([key]) => !seen.has(key))
    .map(([key, value]) => `${key}=${value}`);

  if (missing.length > 0) {
    if (next.length > 0 && next[next.length - 1] !== '') next.push('');
    next.push('# Managed by ag-agentmemory');
    next.push(...missing);
  }

  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${next.join('\n').replace(/\n+$/, '')}\n`, 'utf8');
  return filePath;
}

export async function readEnvValues(filePath = agentmemoryEnvPath()): Promise<Record<string, string>> {
  const current = await fs.readFile(filePath, 'utf8').catch(() => '');
  const values: Record<string, string> = {};
  for (const line of current.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (match) values[match[1]!] = match[2]!;
  }
  return values;
}
