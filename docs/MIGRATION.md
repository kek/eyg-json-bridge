# Consumer migration: eyg-runtime 0.1.1 → eyg-json-bridge 0.2.0

This release narrows the package to a bounded structural JSON bridge. It does not
change EYG language semantics, add standard effects or migrate consumer code
automatically. The upstream dependency versions remain pinned as before.

## Names and compatibility

| Before | Now |
| --- | --- |
| Repository `kek/eyg-runtime` | `kek/eyg-json-bridge` |
| npm package `@kek/eyg-runtime` | `@kek/eyg-json-bridge` |
| Gleam package/module `eyg_runtime` | `eyg_json_bridge` |
| Node export `@kek/eyg-runtime/runtime` | `@kek/eyg-json-bridge/bridge` |
| `eyg_runtime/engine` | Removed; use upstream APIs directly |
| Public `Shape`, `Contract`, continuation constructor | Internal shapes/contracts; opaque continuation |

`start`, `resume`, `Step` variants and JS accessor names retain their behavior.
Node wire protocol **version 1 is unchanged**, including errors, budgets, exact
record validation and request/response ordering. Do not change frame `version`
to 2. There are no old-name compatibility exports. Continuations must not cross
processes, package versions or the old/new module boundary; drain or terminate
old workers before switching.

## Upgrade a Node worker consumer

From the consumer checkout (Node 24+):

```sh
npm uninstall @kek/eyg-runtime
npm install --ignore-scripts https://github.com/kek/eyg-json-bridge/releases/download/v0.2.0/kek-eyg-json-bridge-0.2.0.tgz
```

Commit the consumer's manifest and lockfile. Pin the artifact URL and integrity;
verify SHA256SUMS when distributing the archive outside npm. Update imports:

```js
import { program, literal } from '@kek/eyg-json-bridge/input';
import * as bridge from '@kek/eyg-json-bridge/bridge';
```

Only import `bridge` for in-process structural embedding. For the worker, resolve
`@kek/eyg-json-bridge/worker` or configure the installed
`node_modules/@kek/eyg-json-bridge/node/worker.mjs` path. Importing the worker
executes it and starts reading stdin; it is not a client library.

Keep existing v1 start/effect-response frames. Start one worker per evaluation,
strip its environment, enforce an independent deadline/memory limit, and accept
a terminal result only after successful exit. Recheck host grants and
resource-specific arguments before every backend operation. Malformed replies,
disconnection and uncertain mutations must terminate rather than resume as a
catchable application failure. Never retry an uncertain mutation automatically.

## Moving toward upstream EYG and touch_grass

Upstream already provides:

- `eyg_parser`: source → AST.
- `eyg_analysis`: inference/checking under a host-selected effect context.
- `eyg_interpreter`: `expression.execute` and `expression.resume`, including
  breaks carrying environment and continuation stack.
- `touch_grass`: common effect interfaces, EYG argument/result types, codecs and
  composable harnesses. It does not implement the actual I/O or authorization.

Sources: [upstream repository](https://github.com/CrowdHailer/eyg-lang),
[interpreter 9.0.0 API](https://hexdocs.pm/eyg_interpreter/9.0.0/eyg/interpreter/expression.html),
[touch_grass source and usage](https://github.com/CrowdHailer/eyg-lang/tree/main/packages/touch_grass).

### Choose the boundary deliberately

1. **JSON/process boundary:** keep this bridge. Its dynamic schemas are wire
   contracts, not a replacement catalog of standard EYG effects. Custom domain
   effects such as game actions remain consumer-defined.
2. **Native embedding:** depend directly on upstream parser, analysis,
   interpreter and `touch_grass`. Own the parse/check/execute loop and pass
   validated native values to upstream `resume`. Do not recreate the removed
   `engine` wrapper as a second general-purpose framework.

### Tested native starting point

This dependency combination was exercised in a separate scratch project on both
JavaScript and Erlang with the example below:

```toml
[dependencies]
gleam_stdlib = "1.0.5"
eyg_parser = "0.5.2"
eyg_analysis = "3.0.1"
eyg_interpreter = "9.0.0"
touch_grass = "0.4.4"
```

Commit the consumer's resolved manifest, including transitive versions. This is
an integration starting point, not a new dependency of the JSON bridge or a
claim of compatibility with every future upstream release.

This minimal fixture checks, decodes and resumes the upstream `Print` interface
without performing real I/O. Assertions make it a smoke test, not a production
handler loop; production hosts must handle errors and repeated effects explicitly.

```gleam
import eyg/analysis/inference/levels_j/contextual as infer
import eyg/interpreter/break
import eyg/interpreter/expression
import eyg/interpreter/value
import eyg/parser
import touch_grass as tg
import touch_grass/interface
import touch_grass/print

pub fn main() {
  let effects = [tg.print()]
  let context = infer.with_effects(infer.pure(), interface.types(effects))
  let assert Ok(ast) = parser.all_from_string("perform Print(\"hello\")")
  let assert infer.Done(analysis) = infer.check(context, ast)
  let assert [] = infer.all_errors(analysis)
  let assert Error(#(break.UnhandledEffect(name, argument), _, env, stack)) =
    expression.execute(ast, [])
  let assert "Print" = name
  let assert Ok("hello") = interface.cast(effects, name, argument)
  // A real host authorizes and performs logging here; this fixture does no I/O.
  let assert Ok(value.Record(_)) =
    expression.resume(print.encode(Nil), env, stack)
}
```

`Print` resumes with unit via its upstream encoder, not `Result(unit, String)`.
This is why the native path is distinct from the JSON bridge.

### Migrate interfaces one at a time

For each existing common effect:

1. Compare its argument type, result type, label and error behavior with the
   corresponding `touch_grass` interface, e.g. file reads, clock or randomness.
2. Adopt the upstream interface and codecs when the semantics actually match.
   Compose only the required subset into the consumer's harness and type context.
3. Preserve narrower authorization in the handler: an interface is not a grant.
   Do not replace workspace-scoped access with unrestricted filesystem access.
4. When the semantics differ, retain a clearly named custom effect. Do not reuse
   an upstream label with an incompatible signature just to look standardized.
5. Test argument decoding and reply encoding against the selected upstream
   interface, plus host denials and failure behavior, before removing old codecs.

The bridge cannot losslessly represent every upstream interface: binaries,
arbitrary tags/unions, functions and closures are outside its JSON subset. Also,
every bridge effect returns `Result(reply, String)`; some upstream effects have
other return conventions. A matching name alone is not wire compatibility.
Do not silently coerce these types or change the v1 protocol. Use a native host
adapter for those interfaces, or keep an explicitly documented custom JSON
interface. There is no automatic `touch_grass` ↔ JSON schema converter here.

## Factorio Control

### Immediate upgrade

- Update the pinned archive, lockfile/dependency acquisition and worker path to
  v0.2.0 as above. Keep the existing Elixir Port framing/ownership and Node v1
  protocol; package renaming requires no gameplay or wire changes.
- Keep Factorio-specific effect definitions, validation, game/RCON handlers,
  operation receipts and recovery in Factorio Control. Do not put them here or
  model game actions as generic filesystem/network effects.
- Preserve host deadlines, port cleanup and uncertain-operation handling.

### Upcoming native BEAM adapter

- For the same JSON contracts, embed `eyg_json_bridge.start/resume` on Erlang and
  retain each continuation in the evaluator process. Replace the Node transport,
  not the domain handler contract. Reimplement adapter-owned acquisition/byte
  limits and lifecycle controls; a Gleam call alone supplies no worker deadline.
- If adopting richer `touch_grass` interfaces, use upstream EYG directly instead.
  Select upstream common effects individually; keep game effects custom.
- Keep pure evaluation in a separately monitored/killable process, with deadlines
  enforced externally. Terminating that process does not roll back game actions.
- Run old/new adapter fixtures for game observations, successful actions,
  catchable operation errors, denied actions, wrong reply types, effect budgets,
  disconnect/death and uncertain submissions. Test the documented wide-integer
  target difference explicitly rather than assuming Node/BEAM equivalence.

## Pi

### Immediate upgrade

- Generic v1 worker users update the package/imports/path as above and retain
  their host-side grants, filesystem confinement, approval plans and receipts.
- Pi's legacy snapshot and duplex-v8 protocols are not implemented by this
  bridge. Keep their adapters in Pi; changing the package name does not convert
  them to NDJSON. Migrate them separately only if their actual types fit v1.
- Any Pi adapter importing `eyg_runtime/engine` must switch to direct upstream
  APIs before updating. Use `parser.all_from_string`, check with the selected
  `infer` context, reject analysis errors/lookups as appropriate, then use
  `expression.execute/resume`. Preserve Pi's reference/import denial policy.
  Upstream resume takes a native EYG value, environment and continuation stack;
  validate the host reply before calling it.

### Upstream interface adoption

- Compare Pi's standard-like effects against `touch_grass` individually. Binary
  JSON decoding and unit-returning logging may require native embedding rather
  than this bridge's `Result(JSON, String)` convention.
- Workspace snapshots, LSP/AST inspection, approved proposals, Workbench handles
  and sandbox routing are Pi-specific capabilities. Keep their custom interfaces
  and all policy enforcement in Pi; do not rename them to broader standard I/O.
- Pin upstream dependencies in Pi's native adapter, replace matching custom
  codecs with `touch_grass` codecs, and keep the evaluator process isolated from
  host authority. No ambient credentials or unrestricted I/O should be added as
  a consequence of adopting standard interface definitions.
- Verify pure evaluation, every supported effect, malformed replies, deadlines,
  cancellation, denied paths, stale proposals and uncertain mutation receipts.
  Run these tests through the real Pi adapters, not only this package's tests.

## Rollout and rollback

Upgrade package/path names independently of effect-interface changes. First run
existing consumer fixtures unchanged on v1, then migrate interfaces in separate
consumer changes. Neither consumer checkout is changed by this release.
Keep v0.1.1 available for rollback; restart evaluations on the selected version,
never resume an old continuation with the new package. Do not replay external
mutations as part of rollback.
