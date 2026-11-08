# Changelog

## 0.3.0

- Add native Erlang/Elixir adapter `eyg_json_bridge_beam`: a monitored guardian
  owns a linked evaluator process and run-specific asynchronous effect requests.
- Enforce deadlines during pure evaluation, owner-death cleanup, cancellation,
  pending reply IDs, payload/output budgets and per-evaluator OTP heap limits.
- Add safe native JSON input encoding with `start/4`; `start/3` accepts already
  prepared source. Neither path requires Node or a Port.
- Keep continuations in the evaluator and distinguish typed application errors
  from terminal adapter failures. Terminal events follow evaluator shutdown.
- Document native deployment, options, limits and Factorio's Port-to-BEAM rollout
  in [docs/BEAM.md](docs/BEAM.md).
- Add native lifecycle/contract tests. Node wire protocol v1, structural core and
  pinned upstream package versions are unchanged.

## 0.2.0

Breaking package/API rename and scope reduction:

- Rename repository to `kek/eyg-json-bridge`, npm package to
  `@kek/eyg-json-bridge`, and Gleam package/module to `eyg_json_bridge`.
- Rename the Node `./runtime` export to `./bridge`; keep `./worker` and `./input`.
- Remove the public low-level `eyg_runtime/engine` wrapper. Native integrations
  should use upstream parser, analysis and interpreter APIs directly.
- Make schema/contract implementation types internal and continuations opaque.
- Retain bounded structural JSON contracts, effect count checks, Node NDJSON
  transport and input encoding. Wire protocol v1 and upstream pins are unchanged.
- Document Pi and Factorio upgrades, native BEAM integration boundaries and
  selective adoption of upstream `touch_grass` interfaces/codecs.

This release does not ship a BEAM transport, add `touch_grass` as a dependency,
change consumer handlers, or migrate the consumer repositories.

See [docs/MIGRATION.md](docs/MIGRATION.md) for required consumer changes.

## 0.1.1

Initial extracted host-neutral evaluation wrapper, bounded Node worker,
artifact packaging and JavaScript/Erlang checks, published as `eyg-runtime`.
