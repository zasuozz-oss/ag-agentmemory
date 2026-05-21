#!/usr/bin/env node
import { Command } from 'commander';
import { runSetup } from './setup/setup-command.js';
import { verifySetup } from './setup/verify.js';

const program = new Command();

program
  .name('agentmemory-ag')
  .description('AgentMemory setup automation for Antigravity, Codex CLI, and Claude Code')
  .version('0.1.0');

program
  .command('setup')
  .description('Configure AgentMemory for one or more clients')
  .option('--client <client>', 'all, antigravity, codex, or claude-code', 'all')
  .option('--skip-upstream', 'skip cloning/updating the local AgentMemory upstream snapshot', false)
  .action(async (options) => {
    const result = await runSetup({ client: options.client, syncUpstream: !options.skipUpstream });
    for (const line of result.messages) console.log(line);
  });

program
  .command('sync-upstream')
  .description('Clone or update local AgentMemory upstream source snapshot')
  .action(async () => {
    const { syncAgentmemorySource } = await import('./setup/source-sync.js');
    const result = await syncAgentmemorySource();
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  });

program
  .command('verify')
  .description('Verify AgentMemory setup')
  .action(async () => {
    const result = await verifySetup();
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  });

program
  .command('status')
  .description('Print AgentMemory setup status without failing')
  .action(async () => {
    const result = await verifySetup();
    console.log(JSON.stringify(result, null, 2));
  });

program.parseAsync(process.argv).catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
