import fs from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { AGENTMEMORY_ENV_VALUES, agentmemoryEnvPath, readEnvValues } from './env-file.js';
import { antigravityMcpPath, codexConfigPath } from './mcp-config.js';
import { antigravitySkillsPath } from './skills.js';
import { hasCommand } from './upstream.js';
import path from 'node:path';
import os from 'node:os';

export type VerificationCheck = {
  name: string;
  ok: boolean;
  message: string;
};

export type VerificationResult = {
  ok: boolean;
  checks: VerificationCheck[];
};

function checkNode(): VerificationCheck {
  const major = Number.parseInt(process.versions.node.split('.')[0] || '0', 10);
  return {
    name: 'node',
    ok: major >= 20,
    message: `Node.js ${process.versions.node}`,
  };
}

function commandCheck(command: string): VerificationCheck {
  return {
    name: command,
    ok: hasCommand(command),
    message: hasCommand(command) ? `${command} found` : `${command} not found`,
  };
}

async function checkEnv(): Promise<VerificationCheck> {
  const values = await readEnvValues();
  const missing = Object.entries(AGENTMEMORY_ENV_VALUES)
    .filter(([key, value]) => values[key] !== value)
    .map(([key]) => key);
  return {
    name: 'agentmemory env',
    ok: missing.length === 0,
    message: missing.length === 0
      ? `${agentmemoryEnvPath()} has local embedding config`
      : `${agentmemoryEnvPath()} missing or mismatched: ${missing.join(', ')}`,
  };
}

async function checkAntigravity(): Promise<VerificationCheck> {
  try {
    const raw = await fs.readFile(antigravityMcpPath(), 'utf8');
    const parsed = JSON.parse(raw) as { mcpServers?: Record<string, unknown> };
    const ok = Boolean(parsed.mcpServers?.agentmemory);
    return {
      name: 'antigravity mcp',
      ok,
      message: ok ? `${antigravityMcpPath()} has agentmemory` : `${antigravityMcpPath()} missing agentmemory`,
    };
  } catch (error) {
    return {
      name: 'antigravity mcp',
      ok: false,
      message: `${antigravityMcpPath()} unreadable: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

async function checkAntigravitySkills(): Promise<VerificationCheck> {
  const required = [
    'agentmemory-recall',
    'agentmemory-observe',
    'agentmemory-session-start',
    'agentmemory-session-end',
    'agentmemory-setup',
  ];
  const missing: string[] = [];
  for (const skill of required) {
    try {
      await fs.access(`${antigravitySkillsPath()}/${skill}/SKILL.md`);
    } catch {
      missing.push(skill);
    }
  }
  return {
    name: 'antigravity skills',
    ok: missing.length === 0,
    message: missing.length === 0
      ? `${antigravitySkillsPath()} has required skills`
      : `missing skills: ${missing.join(', ')}`,
  };
}

async function checkCodex(): Promise<VerificationCheck> {
  const config = await fs.readFile(codexConfigPath(), 'utf8').catch(() => '');
  const hasMcp = config.includes('[mcp_servers.agentmemory]');
  return {
    name: 'codex setup',
    ok: hasMcp || hasCommand('codex'),
    message: hasMcp
      ? `${codexConfigPath()} has MCP fallback`
      : hasCommand('codex')
        ? 'codex command found; upstream plugin can be installed by setup'
        : 'codex not found and MCP fallback not configured',
  };
}

async function checkSourceSnapshot(): Promise<VerificationCheck> {
  const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
  const working = path.join(root, 'agentmemory');
  const hasPackage = await fs.access(path.join(working, 'package.json')).then(() => true).catch(() => false);
  const hasGit = await fs.access(path.join(working, '.git')).then(() => true).catch(() => false);
  return {
    name: 'upstream source snapshot',
    ok: hasPackage && !hasGit,
    message: hasPackage && !hasGit
      ? `${working} exists without .git`
      : `${working} missing package.json or still has .git`,
  };
}

function checkHealth(): VerificationCheck {
  const result = spawnSync('curl', ['-fsSL', 'http://localhost:3111/agentmemory/health'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return {
    name: 'agentmemory health',
    ok: result.status === 0,
    message: result.status === 0
      ? 'http://localhost:3111/agentmemory/health responded'
      : 'server not running; start with: npx -y @agentmemory/agentmemory@latest',
  };
}

export async function verifySetup(): Promise<VerificationResult> {
  const checks = [
    checkNode(),
    commandCheck('npx'),
    await checkEnv(),
    await checkAntigravity(),
    await checkAntigravitySkills(),
    await checkCodex(),
    await checkSourceSnapshot(),
    {
      name: 'claude-code setup',
      ok: hasCommand('agentmemory') || hasCommand('claude'),
      message: hasCommand('agentmemory')
        ? 'agentmemory command found; setup can run agentmemory connect claude-code'
        : hasCommand('claude')
          ? 'claude command found; use /plugin marketplace add rohitg00/agentmemory then /plugin install agentmemory'
          : 'agentmemory/claude not found; install manually in Claude Code',
    },
    checkHealth(),
  ];
  return {
    ok: checks.every((check) => check.ok || check.name === 'agentmemory health'),
    checks,
  };
}
