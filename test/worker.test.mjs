import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const worker = fileURLToPath(new URL('../node/worker.mjs', import.meta.url));
const integer = { kind: 'integer' };
const record = fields => ({ kind: 'record', fields });
const contracts = { ReadCount: { argument: record({}), result: integer } };
function run(code, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [worker], { stdio: ['pipe', 'pipe', 'pipe'] });
    const frames = [];
    let buffer = '', stderr = '';
    const timeout = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('test worker timed out')); }, 3000);
    child.on('error', reject);
    child.stdin.on('error', () => {});
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.stdout.on('data', chunk => {
      buffer += chunk;
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const frame = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        frames.push(frame);
        if (frame.type === 'effect-request') {
          if (options.disconnect) child.stdin.end();
          else child.stdin.write(`${JSON.stringify({ version: 1, type: 'effect-response', id: frame.id,
            ok: true, value: 3, ...options.reply })}\n`);
        }
      }
    });
    child.on('close', status => { clearTimeout(timeout); resolve({ status, frames, stderr }); });
    child.stdin.write(`${JSON.stringify({ version: 1, type: 'start', code, contracts, ...options.start })}\n`);
  });
}

test('host-defined effects suspend and resume without Pi', async () => {
  const result = await run('match perform ReadCount({}) { Ok(n) -> {!int_add(n, 1)} Error(_) -> {0} }');
  assert.equal(result.status, 0);
  assert.deepEqual(result.frames.at(-1), { version: 1, type: 'result', ok: true, value: 4 });
  assert.equal(result.frames[0].effect, 'ReadCount');
});

test('records, lists and booleans have fixed typed replies', async () => {
  const result = await run('match perform Observe({}) { Ok(x) -> {x} Error(_) -> {{items: [], complete: False({})}} }', {
    start: { contracts: { Observe: { argument: record({}), result: record({ items: { kind: 'list', items: integer }, complete: { kind: 'boolean' } }) } } },
    reply: { value: { items: [1, 2], complete: true } },
  });
  assert.equal(result.frames.at(-1).ok, true);
  assert.deepEqual(result.frames.at(-1).value, { items: [1, 2], complete: true });
});

test('ungranted effects and wrong argument types fail before any handler request', async () => {
  for (const code of ['perform Shell("echo bad")', 'perform ReadCount(1)']) {
    const { frames } = await run(code);
    assert.equal(frames.length, 1);
    assert.equal(frames[0].ok, false);
    assert.match(frames[0].error, /type check/);
  }
});

test('ordinary operation denial is catchable', async () => {
  const { frames } = await run('match perform ReadCount({}) { Ok(n) -> {n} Error(_) -> {42} }', { reply: { ok: false, error: 'denied' } });
  assert.equal(frames.at(-1).value, 42);
});

test('malformed, unsafe and out-of-sequence replies stop without resumption', async () => {
  for (const reply of [{ value: '3' }, { value: 1.5 }, { value: 2 ** 53 }, { id: 2 }, { version: 99 }]) {
    const { frames, status } = await run('perform ReadCount({})', { reply });
    assert.equal(status, 1);
    assert.equal(frames.at(-1).type, 'error');
  }
});

test('extra response fields cannot silently change an exact record', async () => {
  const { frames } = await run('perform Observe({})', {
    start: { contracts: { Observe: { argument: record({}), result: record({ count: integer }) } } },
    reply: { value: { count: 1, extra: 2 } },
  });
  assert.match(frames.at(-1).error, /exact record/);
});

test('effect budget is enforced by the evaluator', async () => {
  const { frames } = await run('let _ = perform ReadCount({})\nperform ReadCount({})', { start: { max_effects: 1 } });
  assert.equal(frames.filter(f => f.type === 'effect-request').length, 1);
  assert.match(frames.at(-1).error, /budget/);
});

test('host disconnect cannot become a catchable mutation failure', async () => {
  const { frames, status } = await run('perform ReadCount({})', { disconnect: true });
  assert.equal(status, 1);
  assert.match(frames.at(-1).error, /disconnected/);
});

test('unsupported contracts and input floats fail before evaluation', async () => {
  for (const start of [{ contracts: { ReadCount: { argument: record({}), result: { kind: 'any' } } } }, { inputs: { x: 0.5 } }]) {
    const { frames, status } = await run('perform ReadCount({})', { start });
    assert.equal(status, 1);
    assert.equal(frames.length, 1);
    assert.equal(frames[0].type, 'error');
  }
});

test('start contract bounds fail closed before any handler request', async () => {
  let deep = integer;
  for (let i = 0; i < 10; i++) deep = { kind: 'list', items: deep };
  const tooMany = Object.fromEntries(Array.from({ length: 33 }, (_, i) => [`Effect${i}`, contracts.ReadCount]));
  for (const start of [
    { max_effects: 0 }, { max_effects: 101 }, { contracts: tooMany },
    { contracts: { bad: contracts.ReadCount } },
    { contracts: { ReadCount: { argument: record({}), result: deep } } },
    { contracts: { ReadCount: { argument: record({}), result: { kind: 'integer', extra: true } } } },
  ]) {
    const result = await run('0', { start });
    assert.equal(result.status, 1);
    assert.equal(result.frames.length, 1);
    assert.equal(result.frames[0].type, 'error');
  }
});

test('initial frame, continuation frame and final-value budgets fail closed', async () => {
  const initial = await run('0', { start: { padding: 'x'.repeat(1_000_001) } });
  assert.equal(initial.status, 1);
  assert.match(initial.frames.at(-1).error, /frame exceeds/);
  const continuation = await run('perform ReadCount({})', { reply: { padding: 'x'.repeat(64_001) } });
  assert.equal(continuation.status, 1);
  assert.equal(continuation.frames.at(-1).type, 'error');
  const result = await run('input.text', { start: { inputs: { text: 'x'.repeat(12_001) } } });
  assert.equal(result.status, 1);
  assert.match(result.frames.at(-1).error, /Result exceeds/);
});

test('input restrictions and references fail without backend requests', async () => {
  for (const inputs of [{ x: null }, { x: 2 ** 53 }, { 'bad-key': 1 }]) {
    const result = await run('0', { start: { inputs } });
    assert.equal(result.status, 1);
    assert.equal(result.frames.length, 1);
    assert.equal(result.frames[0].type, 'error');
  }
  const result = await run('input.missing');
  assert.equal(result.frames.length, 1);
  assert.equal(result.frames[0].ok, false);
});
