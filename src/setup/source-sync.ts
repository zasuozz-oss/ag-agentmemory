import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const UPSTREAM_URL = 'https://github.com/rohitg00/agentmemory.git';

export type SourceSyncResult = {
  ok: boolean;
  cachePath: string;
  workingPath: string;
  action: 'cloned' | 'updated' | 'used-cache' | 'skipped';
  message: string;
};

function projectRoot(): string {
  return path.resolve(__dirname, '..', '..');
}

function run(command: string, args: string[], cwd: string): { ok: boolean; message: string } {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const message = result.stderr.trim() || result.stdout.trim() || `exit ${result.status ?? 'unknown'}`;
  return { ok: result.status === 0, message };
}

async function exists(filePath: string): Promise<boolean> {
  return fs.access(filePath).then(() => true).catch(() => false);
}

async function copyWithoutGit(src: string, dest: string): Promise<void> {
  await fs.mkdir(dest, { recursive: true });
  await fs.cp(src, dest, {
    recursive: true,
    force: true,
    filter: (source) => !source.split(path.sep).includes('.git'),
  });
  await fs.rm(path.join(dest, '.git'), { recursive: true, force: true }).catch(() => {});
}

export async function syncAgentmemorySource(root = projectRoot()): Promise<SourceSyncResult> {
  const cachePath = path.join(root, '.agentmemory-upstream');
  const workingPath = path.join(root, 'agentmemory');
  const hasCacheGit = await exists(path.join(cachePath, '.git'));

  let action: SourceSyncResult['action'] = hasCacheGit ? 'updated' : 'cloned';
  let gitResult: { ok: boolean; message: string };

  if (hasCacheGit) {
    gitResult = run('git', ['-C', cachePath, 'pull', '--ff-only'], root);
    if (!gitResult.ok) {
      action = 'used-cache';
      gitResult = { ok: true, message: `pull failed; using existing cache (${gitResult.message})` };
    }
  } else {
    await fs.rm(cachePath, { recursive: true, force: true }).catch(() => {});
    gitResult = run('git', ['clone', UPSTREAM_URL, cachePath], root);
  }

  if (!gitResult.ok) {
    const hasWorkingCopy = await exists(workingPath);
    return {
      ok: hasWorkingCopy,
      cachePath,
      workingPath,
      action: hasWorkingCopy ? 'used-cache' : 'skipped',
      message: hasWorkingCopy
        ? `clone failed; keeping existing working copy (${gitResult.message})`
        : `clone failed and no working copy exists (${gitResult.message})`,
    };
  }

  await copyWithoutGit(cachePath, workingPath);
  return {
    ok: true,
    cachePath,
    workingPath,
    action,
    message: gitResult.message,
  };
}
