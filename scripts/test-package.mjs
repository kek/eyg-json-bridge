// Exercise the distributable outside the checkout, with no build/install hooks.
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
const dir = await mkdtemp(join(tmpdir(), 'eyg-package-'));
try {
  // Simulate generated output left over after upgrading an old checkout.
  const stale = new URL('../build/dev/javascript/eyg_runtime/', import.meta.url);
  await mkdir(stale, { recursive: true });
  await writeFile(new URL('stale.mjs', stale), '// retired project output\n');
  const packed = JSON.parse(execFileSync('npm', ['pack', '--json', '--pack-destination', dir], { encoding: 'utf8' }));
  const archive = join(dir, packed[0].filename);
  execFileSync('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', '--prefix', dir, archive], { stdio: 'pipe' });
  const worker = resolve(dir, 'node_modules/@kek/eyg-json-bridge/node/worker.mjs');
  const input = { version: 1, type: 'start', code: '!int_add(input.n, 1)', inputs: { n: 41 }, contracts: {} };
  const child = spawnSync(process.execPath, [worker], { input: JSON.stringify(input) + '\n', encoding: 'utf8', timeout: 5000, env: { NODE_ENV: 'production' } });
  assert.equal(child.status, 0, child.stderr);
  assert.deepEqual(JSON.parse(child.stdout), { version: 1, type: 'result', ok: true, value: 42 });
  await writeFile(join(dir, 'input-check.mjs'), "import { program } from '@kek/eyg-json-bridge/input'; if (!program('input.x', {x: 1}).includes('x: 1')) throw Error('bad input export');\n");
  execFileSync(process.execPath, [join(dir, 'input-check.mjs')]);
  await writeFile(join(dir, 'bridge-check.mjs'), `
import assert from 'node:assert/strict';
import * as bridge from '@kek/eyg-json-bridge/bridge';
assert.equal(bridge.kind(bridge.start('42', '{}', 1)), 'done');
const contracts = JSON.stringify({ReadCount: {argument: {kind: 'record', fields: {}}, result: {kind: 'integer'}}});
const step = bridge.start('match perform ReadCount({}) { Ok(n) -> {n} Error(_) -> {0} }', contracts, 1);
assert.equal(bridge.kind(step), 'effect');
assert.equal(bridge.value(bridge.resume(bridge.continuation(step), true, '7')), '7');
await assert.rejects(import('@kek/eyg-json-bridge/runtime'), {code: 'ERR_PACKAGE_PATH_NOT_EXPORTED'});
`);
  execFileSync(process.execPath, [join(dir, 'bridge-check.mjs')]);
  const root = resolve(dir, 'node_modules/@kek/eyg-json-bridge');
  const manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
  assert.equal(manifest.name, '@kek/eyg-json-bridge');
  assert.equal(manifest.version, '0.2.0');
  assert.deepEqual(Object.keys(manifest.exports).sort(), ['./bridge', './input', './worker']);
  await access(join(root, 'docs/MIGRATION.md'));
  await access(join(root, 'CHANGELOG.md'));
  await assert.rejects(access(join(root, 'dist/eyg_runtime')));
  await assert.rejects(access(join(root, 'dist/eyg_json_bridge/eyg_json_bridge/engine.mjs')));
  await assert.rejects(access(join(root, 'src/eyg_json_bridge/engine.gleam')));
  console.log('PASS: renamed artifact, public bridge/input exports, typed resumption, migration docs and removed engine API');
} finally { await rm(dir, { recursive: true, force: true }); }
