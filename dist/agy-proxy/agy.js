import { spawn } from 'node:child_process';
const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_PROMPT_BYTES = 200_000;
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
    const bin = options.bin || process.env.AGY_CLI_BIN || `${process.env.HOME || ''}/.local/bin/agy`;
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
        const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'], cwd });
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
        .replace(/\u001b\[[0-9;]*m/g, '')
        .trim();
}
