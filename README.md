# eyg-json-bridge

A bounded JSON bridge to upstream [EYG](https://eyg.run/) evaluation and
host-defined effects. This is an embedding/transport package, not another EYG
interpreter or a standard effect library. Licensed Apache-2.0.

## Scope

- Compose the upstream parser, typechecker and interpreter, pinned in
  `manifest.toml`.
- Translate a deliberately limited JSON contract description into EYG types.
- Expose `Done`, `Failed` or a typed effect request with an opaque, process-local
  continuation; decode JSON replies before resuming the upstream interpreter.
- Provide a bounded Node NDJSON adapter and literal input encoding.
- Provide a native BEAM process adapter with owner monitoring, deadlines,
  cancellation and per-evaluator heap limits.

Upstream EYG owns language semantics, evaluation and continuations.
[`touch_grass`](https://github.com/CrowdHailer/eyg-lang/tree/main/packages/touch_grass)
owns common effect interfaces, types and codecs. Hosts own concrete handlers,
grants, credentials, approvals, deadlines, cancellation, receipts and recovery.
This package neither replaces those interfaces nor implements those policies.

Use the bridge when you need a JSON/process boundary. For native EYG values,
binaries, arbitrary tags, closures or custom type contexts, use upstream packages
and `touch_grass` directly. There is no public low-level engine wrapper here.
See [consumer migration guidance](docs/MIGRATION.md) for Pi and Factorio.

No source imports, dynamic package loading or ambient EYG I/O are enabled.
Selecting a contract does not authorize a resource. The Node worker has the
user's OS permissions: it is **not a hardened hostile-code sandbox**.

## Install the Node artifact

Requires Node 24+. Release packages contain generated JavaScript and Gleam
source; installing/running them requires neither Gleam nor install scripts.
There is no npm-registry publication.

```sh
npm install --ignore-scripts https://github.com/kek/eyg-json-bridge/releases/download/v0.3.0/kek-eyg-json-bridge-0.3.0.tgz
export EYG_WORKER="$PWD/node_modules/@kek/eyg-json-bridge/node/worker.mjs"
node --max-old-space-size=128 "$EYG_WORKER"
```

The final command reads NDJSON from stdin; it is not an interactive REPL.
Pin the release URL and lockfile integrity in consumers. For manual downloads,
verify the release's SHA256SUMS. Treat release artifacts as immutable; corrections
get a new version. The package has no runtime npm dependencies.

Public Node exports:
- `@kek/eyg-json-bridge/worker`: executable entry point (starts reading stdin).
- `@kek/eyg-json-bridge/input`: `literal(value)` and `program(code, inputs)`.
- `@kek/eyg-json-bridge/bridge`: compiled structural start/resume accessors.

Use these exports or the documented worker path, not generated module paths.
See [PROTOCOL.md](PROTOCOL.md) for wire protocol v1, unchanged from v0.1.1.

## Gleam embedding and BEAM adapters

Add a pinned source checkout or the source included in the Node package as a
Gleam path dependency:

```toml
[dependencies]
eyg_json_bridge = { path = "node_modules/@kek/eyg-json-bridge" }
```

`eyg_json_bridge.start(source, contracts_json, max_effects)` returns a `Step`:
`Done(value_json)`, `Failed(reason)`, or
`Effect(name, argument_json, continuation)`.
`resume(continuation, successful, response)` accepts typed JSON on success or
plain error text on failure. Host errors resume as EYG `Result(_, String)`.
A malformed typed response fails evaluation. Accessors are available for JS
embedding. Continuations are opaque native process-local values, not
serializable checkpoints or durable jobs.

The bridge validates contract names, schema depth/count/field bounds, exact
records, safe reply integers and effect count on both JavaScript and Erlang.
Transport/frame limits, final-value byte limits, input acquisition, memory limits
and deadlines belong to adapters; the Node adapter supplies the documented byte
limits. The native `eyg_json_bridge_beam` adapter runs the same structural API
in a separate evaluator process, with an independent guardian enforcing lifetime
and payload limits. It uses native BEAM messages, not NDJSON or an Elixir Port.
See [docs/BEAM.md](docs/BEAM.md) for Erlang/Elixir usage and source deployment.
For richer types, use upstream EYG directly.

## Integer portability

Upstream EYG uses target-native integers. JavaScript rejects out-of-safe-range
integer literals and checked arithmetic; Erlang permits arbitrary-precision
intermediate integers. JSON output and structural replies are restricted to
±(2^53−1) on both targets. An Erlang program can therefore convert a large
intermediate integer to a string when the JS program would fail. This bridge
does not redefine upstream arithmetic or promise equivalence outside the
safe-integer domain.

## Build and verify

Build tools: Gleam 1.19.2, Node 24+, Erlang/OTP 29.1.2 and Rebar3 3.28.0.

```sh
npm ci --ignore-scripts
gleam format --check src test
npm run build
npm test
npm run test:core
npm run test:beam
npm run test:package
npm pack
sha256sum kek-eyg-json-bridge-0.3.0.tgz > SHA256SUMS
```

`test:package` installs the packed artifact into a temporary unrelated directory
with install hooks disabled, then exercises its public exports and worker.
The inactive [CI template](docs/ci.yml) runs both targets and uploads the tested
Node package plus checksum when installed as `.github/workflows/test.yml`.
Activation requires GitHub workflow permission. Generated dependency licenses
and provenance are included by the prepack step.

See [CHANGELOG.md](CHANGELOG.md) for v0.3.0 and the v0.2.0 package/API rename.
