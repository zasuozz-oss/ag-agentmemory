import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const START = '<!-- AGENTMEMORY_RULES_START -->';
const END = '<!-- AGENTMEMORY_RULES_END -->';

function projectRoot(): string {
  return path.resolve(__dirname, '..', '..');
}

function templatesRoot(): string {
  return path.join(projectRoot(), 'src', 'templates');
}

function customRoot(): string {
  return path.join(projectRoot(), 'custom');
}

async function resolveTemplate(relative: string): Promise<string> {
  const custom = path.join(customRoot(), relative);
  return fs.access(custom).then(() => custom).catch(() => path.join(templatesRoot(), relative));
}

function escapeRegex(input: string): string {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function upsertBlock(filePath: string, content: string): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  const current = await fs.readFile(filePath, 'utf8').catch(() => '');
  const block = `${START}\n${content.trim()}\n${END}`;
  if (current.includes(START) && current.includes(END)) {
    const re = new RegExp(`${escapeRegex(START)}[\\s\\S]*?${escapeRegex(END)}`);
    await fs.writeFile(filePath, current.replace(re, block), 'utf8');
    return;
  }
  const separator = current.trim() ? '\n\n' : '';
  await fs.writeFile(filePath, `${current.trimEnd()}${separator}${block}\n`, 'utf8');
}

export function antigravityInstructionsPath(home = os.homedir()): string {
  return path.join(home, '.gemini', 'GEMINI.md');
}

export async function installAntigravityInstructions(): Promise<string> {
  const source = await resolveTemplate('instructions/AGENTMEMORY.md');
  const content = await fs.readFile(source, 'utf8');
  const target = antigravityInstructionsPath();
  await upsertBlock(target, content);
  return target;
}
