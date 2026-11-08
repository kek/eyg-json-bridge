# eyg-runtime

Host-neutral [EYG](https://eyg.run) evaluation with typed effects and retained
continuations. The library uses upstream EYG packages for parsing, typechecking
and evaluation, with versions pinned in `manifest.toml`. Licensed Apache-2.0.

## Boundaries

- **Gleam core:** checked execution, structural effect contracts, continuations,
  JSON-compatible value encoding.
- **Node adapter:** bounded NDJSON protocol version 1 and literal input encoding.
- **Hosts:** effect grants, handlers, credentials, approvals, wall-clock deadlines,
  process ownership, cancellation, receipts and domain recovery.

Pi filesystem/inspection/proposal policies and Factorio gameplay operations are
not part of this repository. Selecting a contract does not authorize a resource.
No automatic mutation retries, ambient EYG I/O, source imports or dynamic package
loading are provided. The worker has the user's OS permissions: it is **not a
hardened hostile-code sandbox**.

## Install the Node artifact

Requires Node 24+. Release packages contain generated JavaScript and Gleam
source; installing/running them requires neither Gleam nor install scripts.
There is no npm-registry publication.

```sh
npm install --ignore-scripts https://github.com/kek/eyg-runtime/releases/download/v0.1.1/kek-eyg-runtime-0.1.1.tgz
export EYG_WORKER="$PWD/node_modules/@kek/eyg-runtime/node/worker.mjs"
node --max-old-space-size=128 "$EYG_WORKER"
```

The final command reads NDJSON from stdin; it is not an interactive REPL.
Pin the release URL and lockfile integrity in consumers. For manual downloads,
verify the release's SHA256SUMS. Treat release artifacts as immutable; corrections
get a new version. The package has no runtime npm dependencies.

Public Node exports:
- `@kek/eyg-runtime/worker`: executable worker entry point (starts reading stdin).
- `@kek/eyg-runtime/input`: `literal(value)` and `program(code, inputs)`.
- `@kek/eyg-runtime/runtime`: compiled structural start/resume accessors.

Use these exports or the documented worker path, not generated module paths.
See [PROTOCOL.md](PROTOCOL.md) for the wire contract and limits.

## Gleam embedding

Add a pinned source checkout or the source included in the Node package as a
Gleam path dependency:

```toml
[dependencies]
eyg_runtime = { path = "node_modules/@kek/eyg-runtime" }
```

`eyg_runtime.start(source, contracts_json, max_effects)` returns a `Step`:
`Done(value_json)`, `Failed(reason)`, or
`Effect(name, argument_json, continuation)`.
`resume(continuation, successful, response)` accepts typed JSON on success or
plain error text on failure. Host errors resume as EYG `Result(_, String)`.
A malformed typed response fails evaluation. Accessors are available for JS
embedding. Continuations are native process-local values, not serializable
checkpoints or durable jobs.

The structural core validates contract names, schema depth/count/field bounds,
exact records and safe reply integers on both targets. Transport/frame limits,
source/input acquisition and deadlines belong to adapters.

`eyg_runtime/engine` is a lower-level trusted-host interface for richer EYG types
(such as Pi's binary JSON decoding and unit-returning logging). It centralizes
parse/check/execute and native resumption under a host-supplied type context.
It does not implement the structural protocol's validation or budgets; such
adapters must enforce their own. Pi's effect-handling loops remain in Pi.

## Erlang target and integer semantics

The core builds for JavaScript **and Erlang**, with cross-target smoke tests.
A production BEAM host adapter is deferred; the Node worker is currently the
supported transport for both Pi-related tooling and Factorio Control.

Upstream EYG intentionally uses target-native integers. JavaScript rejects
out-of-safe-range integer literals and checked arithmetic; Erlang permits
arbitrary-precision intermediate integers. JSON output and structural replies
are restricted to ±(2^53−1) on both targets. Consequently whole-program semantics
are not identical outside the safe-integer domain: an Erlang program can convert
a large intermediate integer to a string when the JS program would fail.
Do not claim cross-target numerical equivalence merely from bounded output.
No upstream integer redesign is included in this extraction.

## Build and verify independently

Build tools: Gleam 1.19.2, Node 24+, Erlang/OTP 29.1.2 and Rebar3 3.28.0
for the Erlang check. Run:

```sh
npm ci --ignore-scripts
gleam format --check src test
npm run build
npm test
npm run test:core
npm run test:package
npm pack
sha256sum kek-eyg-runtime-0.1.1.tgz > SHA256SUMS
```

`test:package` installs the packed artifact into a temporary unrelated directory
with install hooks disabled, then executes the worker and input export.
The inactive [CI template](docs/ci.yml) runs both targets and uploads the tested
Node package plus its checksum when installed as `.github/workflows/test.yml`.
Activation requires GitHub credentials with workflow permission; the initial
publication credential lacks that scope. The same checks were run locally.
Generated dependency licenses/provenance are included by the prepack step.
Only release packaging needs a compiler; normal artifact installation does not.

The original Node v1 protocol is preserved. Pi's legacy snapshot and duplex-v8
protocols remain in the Pi integration; they are not supported by this
generic worker. Factorio retains its Elixir Port transport and application
handlers. Neither consumer needs the other's checkout layout.
