import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_PROMPT_BYTES = 200_000;
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..', '..');
const DEFAULT_AGY_BIN = path.join(projectRoot, 'agy-clean-wrapper.sh');
const MAX_CONCURRENCY = Number.parseInt(process.env.AGY_PROXY_CONCURRENCY || '3', 10);
let active = 0;
const waiting = [];
async function acquireSlot() {
    if (active < MAX_CONCURRENCY) {
        active++;
        return;
    }
    return new Promise((resolve) => waiting.push(resolve));
}
function releaseSlot() {
    const next = waiting.shift();
    if (next) {
        next();
    }
    else {
        active--;
    }
}
export async function runAgyPrompt(prompt, options = {}) {
    await acquireSlot();
    try {
        return await runAgyPromptNow(prompt, options);
    }
    finally {
        releaseSlot();
    }
}
async function runAgyPromptNow(prompt, options) {
    const agyBin = options.bin || process.env.AGY_CLI_BIN || DEFAULT_AGY_BIN;
    const timeoutMs = options.timeoutMs || Number.parseInt(process.env.AGY_CLI_TIMEOUT_MS || '', 10) || DEFAULT_TIMEOUT_MS;
    const promptBytes = Buffer.byteLength(prompt, 'utf8');
    if (promptBytes > MAX_PROMPT_BYTES) {
        throw new Error(`agy prompt is ${promptBytes} bytes, above ${MAX_PROMPT_BYTES} byte safety limit`);
    }
    const args = ['--print-timeout', `${Math.ceil(timeoutMs / 1000)}s`, '-p'];
    if (options.sandbox ?? process.env.AGY_CLI_SANDBOX === 'true')
        args.push('--sandbox');
    args.push(prompt);
    return new Promise((resolve, reject) => {
        const cwd = process.env.AGY_PROXY_WORKDIR || '/private/tmp';
        const child = spawn(agyBin, args, { stdio: ['ignore', 'pipe', 'pipe'], cwd });
        let stdout = '';
        let stderr = '';
        const timer = setTimeout(() => {
            child.kill('SIGTERM');
            reject(new Error(`agy timed out after ${timeoutMs}ms`));
        }, timeoutMs + 5_000);
        child.stdout.setEncoding('utf8');
        child.stderr.setEncoding('utf8');
        child.stdout.on('data', (chunk) => { stdout += chunk; });
        child.stderr.on('data', (chunk) => { stderr += chunk; });
        child.on('error', (error) => {
            clearTimeout(timer);
            reject(error);
        });
        child.on('close', (code) => {
            clearTimeout(timer);
            if (code === 0)
                resolve(cleanAgyOutput(stdout));
            else
                reject(new Error(`agy exited ${code}: ${stderr.trim()}`));
        });
    });
}
function cleanAgyOutput(output) {
    return output
        .replace(/\u001b\[[0-9;]*[a-zA-Z]/g, '') // all CSI sequences (color, cursor, erase, …)
        .replace(/\u001b\][^\u001b]*(?:\u0007|\u001b\\)/g, '') // OSC sequences
        .replace(/\u001b[^[\]]/g, '') // remaining lone ESC sequences
        .replace(/\r\n/g, '\n')
        .replace(/\r/g, '')
        .trim();
}
