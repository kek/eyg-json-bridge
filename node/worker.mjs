// Pi-independent NDJSON adapter. Hosts own contracts, grants and deadlines.
import * as bridge from '../dist/eyg_json_bridge/eyg_json_bridge.mjs';
import { program } from './input.mjs';

const VERSION = 1;
const FRAME_BYTES = 64_000;
const plain = value => value !== null && Object.getPrototypeOf(value) === Object.prototype;
const check = (condition, message) => { if (!condition) throw new Error(message); };

function validateShape(shape, depth = 0) {
  check(depth <= 8 && plain(shape), 'Invalid or overly deep contract');
  switch (shape.kind) {
    case 'string': case 'integer': case 'boolean':
      check(Object.keys(shape).length === 1, 'Unexpected scalar contract field'); break;
    case 'list':
      check(Object.keys(shape).length === 2, 'Unexpected list contract field');
      validateShape(shape.items, depth + 1); break;
    case 'record':
      check(Object.keys(shape).length === 2 && plain(shape.fields) && Object.keys(shape.fields).length <= 64, 'Invalid record contract');
      for (const [name, field] of Object.entries(shape.fields)) {
        check(/^[a-z_][a-z0-9_]*$/.test(name), 'Invalid record field name');
        validateShape(field, depth + 1);
      }
      break;
    default: throw new Error('Unsupported contract kind');
  }
}

function validateValue(shape, value) {
  switch (shape.kind) {
    case 'string': check(typeof value === 'string', 'Expected string'); break;
    case 'integer': check(Number.isSafeInteger(value), 'Expected safe integer'); break;
    case 'boolean': check(typeof value === 'boolean', 'Expected boolean'); break;
    case 'list':
      check(Array.isArray(value), 'Expected list');
      for (const item of value) validateValue(shape.items, item);
      break;
    case 'record':
      check(plain(value) && Object.keys(value).length === Object.keys(shape.fields).length, 'Expected exact record');
      for (const [name, field] of Object.entries(shape.fields)) {
        check(Object.hasOwn(value, name), 'Missing record field');
        validateValue(field, value[name]);
      }
      break;
  }
}

async function* frames() {
  let pending = Buffer.alloc(0), first = true, total = 0;
  for await (const chunk of process.stdin) {
    total += chunk.length;
    check(total <= 8_000_000, 'Run input budget exceeded');
    pending = Buffer.concat([pending, chunk]);
    let end;
    while ((end = pending.indexOf(10)) >= 0) {
      const line = pending.subarray(0, end);
      pending = pending.subarray(end + 1);
      check(line.length <= (first ? 1_000_000 : FRAME_BYTES), 'Input frame exceeds limit');
      first = false;
      const value = JSON.parse(line.toString('utf8'));
      check(plain(value) && value.version === VERSION, 'Unsupported protocol frame/version');
      yield value;
    }
    check(pending.length <= (first ? 1_000_000 : FRAME_BYTES), 'Input frame exceeds limit');
  }
  check(!pending.length, 'Unterminated input frame');
}

let outputBytes = 0;
function send(frame) {
  const line = JSON.stringify({ version: VERSION, ...frame });
  outputBytes += Buffer.byteLength(line) + 1;
  check(Buffer.byteLength(line) <= FRAME_BYTES && outputBytes <= 8_000_000, 'Output budget exceeded');
  process.stdout.write(`${line}\n`);
}

try {
  const iterator = frames()[Symbol.asyncIterator]();
  const first = await iterator.next();
  check(!first.done && first.value.type === 'start', 'Expected start frame');
  const { code, inputs = {}, contracts, max_effects = 100 } = first.value;
  check(plain(contracts) && Object.keys(contracts).length <= 32, 'Invalid effect contracts');
  check(Number.isInteger(max_effects) && max_effects >= 1 && max_effects <= 100, 'Invalid effect budget');
  for (const [name, contract] of Object.entries(contracts)) {
    check(/^[A-Z][A-Za-z0-9]*$/.test(name) && plain(contract) && Object.keys(contract).length === 2, 'Invalid effect contract');
    validateShape(contract.argument);
    validateShape(contract.result);
  }
  let step = bridge.start(program(code, inputs), JSON.stringify(contracts), max_effects);
  let id = 0;
  while (bridge.kind(step) === 'effect') {
    const effect = bridge.effect(step), argument = JSON.parse(bridge.argument(step));
    check(Object.hasOwn(contracts, effect), 'Unapproved effect');
    validateValue(contracts[effect].argument, argument);
    send({ type: 'effect-request', id: ++id, effect, argument });
    const next = await iterator.next();
    check(!next.done, 'Host disconnected while awaiting effect reply');
    const reply = next.value;
    check(reply.type === 'effect-response' && reply.id === id && typeof reply.ok === 'boolean', 'Invalid pending effect response');
    if (reply.ok) {
      validateValue(contracts[effect].result, reply.value);
      step = bridge.resume(bridge.continuation(step), true, JSON.stringify(reply.value));
    } else {
      check(typeof reply.error === 'string' && Buffer.byteLength(reply.error) <= 4000, 'Invalid effect error');
      step = bridge.resume(bridge.continuation(step), false, reply.error);
    }
  }
  if (bridge.kind(step) === 'done') {
    const value = JSON.parse(bridge.value(step));
    check(Buffer.byteLength(JSON.stringify(value)) <= 12_000, 'Result exceeds 12 KB');
    send({ type: 'result', ok: true, value });
  } else send({ type: 'result', ok: false, error: bridge.error(step).slice(0, 500) });
} catch (error) {
  try { send({ type: 'error', error: String(error.message).slice(0, 500) }); } catch { /* exhausted transport */ }
  process.exitCode = 1;
} finally {
  process.stdin.destroy();
}
