# Changelog

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
