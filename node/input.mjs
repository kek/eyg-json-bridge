// Input encoding is deliberately narrower than JSON: EYG has no float or null
// literal. Reject unsupported inputs rather than silently changing their type.
const identifier = /^[a-z_][a-z0-9_]*$/;

export function literal(value, depth = 0) {
  if (depth > 32) throw new Error('Input exceeds 32 nesting levels');
  if (typeof value === 'string') {
    // The EYG parser accepts JSON's ordinary escapes, but not all JSON unicode
    // escape forms. Validate the generated source in the interpreter too.
    return JSON.stringify(value);
  }
  if (typeof value === 'number' && Number.isSafeInteger(value)) return String(value);
  if (typeof value === 'boolean') return value ? 'True({})' : 'False({})';
  if (Array.isArray(value)) return `[${value.map(v => literal(v, depth + 1)).join(', ')}]`;
  if (value !== null && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype) {
    return `{${Object.entries(value).map(([key, item]) => {
      if (!identifier.test(key)) throw new Error(`Unsupported input field: ${key.slice(0, 60)}`);
      return `${key}: ${literal(item, depth + 1)}`;
    }).join(', ')}}`;
  }
  throw new Error('Inputs must contain only safe integers, strings, booleans, arrays or records (no null/floats)');
}

export function program(code, inputs = {}) {
  if (typeof code !== 'string' || !code.trim() || code.length > 64_000) throw new Error('Provide EYG source (max 64K characters)');
  if (inputs === null || Array.isArray(inputs) || typeof inputs !== 'object') throw new Error('inputs must be a record');
  // Bound the payload before constructing an EYG literal in the host process.
  let encoded;
  try { encoded = JSON.stringify(inputs); } catch { throw new Error('inputs must be JSON'); }
  if (encoded === undefined || Buffer.byteLength(encoded) > 500_000) throw new Error('Inputs exceed 500 KB');
  const source = `let input = ${literal(inputs)}\n${code}`;
  if (Buffer.byteLength(source) > 1_000_000) throw new Error('Source and inputs exceed 1 MiB');
  return source;
}
