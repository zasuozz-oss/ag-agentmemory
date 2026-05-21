import { spawnSync } from 'node:child_process';

export type CommandResult = {
  ok: boolean;
  command: string;
  message: string;
};

export function hasCommand(command: string): boolean {
  const lookup = process.platform === 'win32' ? 'where' : 'which';
  const result = spawnSync(lookup, [command], { stdio: 'ignore' });
  return result.status === 0;
}

function run(command: string, args: string[]): CommandResult {
  const result = spawnSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const full = `${command} ${args.join(' ')}`;
  const stderr = result.stderr.trim();
  const stdout = result.stdout.trim();
  return {
    ok: result.status === 0,
    command: full,
    message: stderr || stdout || (result.status === 0 ? 'ok' : `exit ${result.status ?? 'unknown'}`),
  };
}

export async function installCodexPlugin(): Promise<{
  ok: boolean;
  attempted: boolean;
  results: CommandResult[];
  fallbackNeeded: boolean;
}> {
  if (!hasCommand('codex')) {
    return { ok: false, attempted: false, results: [], fallbackNeeded: true };
  }

  const add = run('codex', ['plugin', 'marketplace', 'add', 'rohitg00/agentmemory']);
  const install = add.ok
    ? run('codex', ['plugin', 'install', 'agentmemory'])
    : { ok: false, command: 'codex plugin install agentmemory', message: 'skipped because marketplace add failed' };
  const results = [add, install];
  const ok = results.every((result) => result.ok);
  return { ok, attempted: true, results, fallbackNeeded: !ok };
}

export async function connectClaudeCode(): Promise<{
  ok: boolean;
  attempted: boolean;
  result?: CommandResult;
  manualCommands: string[];
}> {
  const manualCommands = [
    '/plugin marketplace add rohitg00/agentmemory',
    '/plugin install agentmemory',
  ];

  if (!hasCommand('agentmemory')) {
    return { ok: false, attempted: false, manualCommands };
  }

  const result = run('agentmemory', ['connect', 'claude-code']);
  return { ok: result.ok, attempted: true, result, manualCommands };
}
