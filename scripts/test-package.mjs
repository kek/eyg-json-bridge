// Exercise the distributable outside the checkout, with no build/install hooks.
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
const dir = await mkdtemp(join(tmpdir(), 'eyg-package-'));
try {
  const packed = JSON.parse(execFileSync('npm', ['pack', '--json', '--pack-destination', dir], { encoding: 'utf8' }));
  const archive = join(dir, packed[0].filename);
  execFileSync('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', '--prefix', dir, archive], { stdio: 'pipe' });
  const worker = resolve(dir, 'node_modules/@kek/eyg-runtime/node/worker.mjs');
  const input = { version: 1, type: 'start', code: '!int_add(input.n, 1)', inputs: { n: 41 }, contracts: {} };
  const child = spawnSync(process.execPath, [worker], { input: JSON.stringify(input) + '\n', encoding: 'utf8', timeout: 5000, env: { NODE_ENV: 'production' } });
  assert.equal(child.status, 0, child.stderr);
  assert.deepEqual(JSON.parse(child.stdout), { version: 1, type: 'result', ok: true, value: 42 });
  await writeFile(join(dir, 'input-check.mjs'), "import { program } from '@kek/eyg-runtime/input'; if (!program('input.x', {x: 1}).includes('x: 1')) throw Error('bad input export');\n");
  execFileSync(process.execPath, [join(dir, 'input-check.mjs')]);
  console.log('PASS: packed artifact installs without hooks and runs outside the source checkout');
} finally { await rm(dir, { recursive: true, force: true }); }
