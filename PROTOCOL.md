# eyg-json-bridge: Node worker protocol v1

Packages v0.2.0 and v0.3.0 retain the v0.1.1 wire protocol unchanged. These JSON
contracts are transport-specific; they are not the upstream `touch_grass` interface format.
See [consumer migration guidance](docs/MIGRATION.md) for native interfaces.
The [BEAM process adapter](docs/BEAM.md) uses the same structural contracts and
JSON values, but native messages rather than these NDJSON frames.

UTF-8 NDJSON on stdin/stdout. Stdout is protocol-only. One evaluation per worker.
The host starts it with a stripped environment and an independent deadline.
Accept a terminal result only after successful worker exit.

Start frame:

```json
{"version":1,"type":"start","code":"match perform ReadCount({}) { Ok(n) -> {n} Error(_) -> {0} }","inputs":{},"max_effects":100,"contracts":{"ReadCount":{"argument":{"kind":"record","fields":{}},"result":{"kind":"integer"}}}}
```

`inputs` defaults to `{}`; `max_effects` defaults to 100. Contracts are host-owned,
never derived from generated source. Shapes are `string`, `integer`, `boolean`,
`list` with `items`, or `record` with named `fields`. Records are exact.
Every declared external effect returns EYG `Result(result, String)`.

Worker → host:

```json
{"version":1,"type":"effect-request","id":1,"effect":"ReadCount","argument":{}}
```

Host → worker (exactly one matching pending ID):

```json
{"version":1,"type":"effect-response","id":1,"ok":true,"value":3}
```

Alternatively `ok:false,error:"reason"` resumes with a catchable application
error. Requests are sequential, IDs start at 1, and continuations stay in the
worker. Success requires a `value`, including `{}` for an empty record.

Terminal frames:

```json
{"version":1,"type":"result","ok":true,"value":3}
{"version":1,"type":"result","ok":false,"error":"type check failed"}
{"version":1,"type":"error","error":"Invalid pending effect response"}
```

Evaluation failures use `result,ok:false`. Protocol failures use `error` and
a nonzero exit. Mismatched IDs, invalid reply types, exhausted transport budgets
and host disconnects do not become catchable operation failures.

## Limits (decimal bytes)

| Limit | Value |
| --- | --- |
| Initial frame | 1,000,000 |
| Subsequent input/output frame | 64,000 |
| Cumulative input; cumulative output | 8,000,000 each |
| Final JSON value | 12,000 |
| Application error text | 4,000 |
| Effect contracts | 32 |
| External effects/run | host-selected 1–100 |
| Schema depth | 8 (root depth 0) |
| Fields/record | 64 |
| Source text supplied to program encoder | 64,000 JS string units |
| Encoded literal inputs | 500,000 |
| Encoded source including inputs | 1,000,000 |
| Literal input nesting | 32 |
| Result encoding nesting | 64 |

Effect names match `[A-Z][A-Za-z0-9]*`; record/input field names match
`[a-z_][a-z0-9_]*`. Literal inputs reject null, floats and unsafe integers.
Unsupported output values (functions, binaries and non-boolean tags) fail.
JSON replies carry plain JSON values, never source text to evaluate.

## Authority, cancellation and uncertain operations

The worker checks declared effects and shapes; the host must independently
check grants and resource-specific arguments **before backend mutation**.
The host owns wall-clock deadlines, process termination, parent-death cleanup
and environment stripping. No in-process Node timer can interrupt infinite pure
computation. No NDJSON cancellation frame exists. The BEAM adapter uses a separate
guardian process to enforce its deadline and cancellation.

If an external mutation may have happened but lacks confirmation, terminate
without resuming with an ordinary `Error`. Keep submission/acceptance/terminal
receipts outside the evaluator and perform domain recovery in the consumer.
Killing the evaluator cannot roll back or reliably stop external operations.
Never automatically retry an uncertain mutation.

Native embedding with upstream EYG and `touch_grass` is outside this protocol.
Such hosts define their own type contexts, codecs and validation. This package
exposes only the structural JSON bridge, not a low-level engine API.
