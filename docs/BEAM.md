# Native BEAM adapter (v0.3.0)

`eyg_json_bridge_beam` is an Erlang module included with the Gleam package. It
runs the structural JSON bridge without Node or an OS Port. It does not install
standard effects or implement game/filesystem/network handlers.

Each run has two processes:

- **Evaluator:** owns the upstream continuation and runs parsing, checking,
  evaluation, argument encoding and typed reply decoding.
- **Guardian:** monitors the owner and evaluator, enforces an absolute deadline,
  checks reply sequencing and payload budgets, and handles cancellation.

The guardian never evaluates EYG. Deadlines and cancellation work even during
an infinite pure computation. The evaluator is linked to the guardian, so an
unexpected guardian crash also terminates the evaluator. Owner death terminates
both. A terminal event is sent only after the evaluator has stopped.

## Build and load

Use Gleam 1.19.2, Erlang/OTP 29.1.2 and Rebar3 3.28.0. Pin the v0.3.0 source
revision and its `manifest.toml` in the consumer's dependency/build pipeline.
A Gleam host can use a path dependency on that source checkout:

```toml
[dependencies]
eyg_json_bridge = { path = "vendor/eyg-json-bridge" }
```

For a standalone source build:

```sh
gleam build --target erlang
sh scripts/test-beam.sh
gleam export erlang-shipment
# Interactive Erlang smoke testing:
erl -pa build/erlang-shipment/*/ebin
```

The shipment contains the application and resolved dependencies. There is no
CLI main function: do not invoke its generated `entrypoint.sh run`. Load the
compiled applications into your Erlang/Elixir host or include them in its release
using the consumer's build integration. Merely declaring a Gleam source checkout
as a Mix dependency does not compile it; the consumer must run a Gleam-aware
build step. Do not load duplicate/incompatible versions of EYG or Gleam dependency
modules into the same VM. Build with a compatible OTP version for deployment.

The Node release archive also includes the Gleam/Erlang source, but npm and Node
are not required for a source-based BEAM integration. No precompiled BEAM archive
or Hex publication is provided by this release.

## API

```erlang
{ok, Run} = eyg_json_bridge_beam:start(Code, InputsJson, ContractsJson, Options).
%% Or, for source that already contains its input binding:
{ok, Run} = eyg_json_bridge_beam:start(PreparedSource, ContractsJson, Options).
GuardianPid = eyg_json_bridge_beam:pid(Run).
ok = eyg_json_bridge_beam:reply(Run, RequestId, {ok, ReplyJson}).
ok = eyg_json_bridge_beam:reply(Run, RequestId, {error, ErrorText}).
ok = eyg_json_bridge_beam:cancel(Run).
```

`Run` is an opaque, run-specific handle. The process calling `start/3` or `start/4` is its
owner and receives its events. Handle possession permits replies/cancellation;
keep it inside the trusted host. Replies and cancellation are asynchronous,
returning `ok` after sending, not after completion. Late messages to a completed
run are harmless and cannot restart it.

All source/JSON arguments are UTF-8 binaries. `start/4` takes EYG `Code` plus a
JSON input record and safely encodes an `input` binding in the evaluator. For
example, code `!int_add(input.n, 1)` with input JSON `{"n":41}` produces `42`.
The native encoder accepts only safe integers, strings, booleans, lists and
identifier-keyed records. Nulls, floating-point JSON tokens, unsafe integers,
invalid fields and inputs nested beyond 32 levels are rejected.

`start/3` instead takes **already prepared EYG source**; it adds no binding.
Use this only when the consumer already has an input encoder. Never concatenate
untrusted strings as executable source. Contracts use exactly the structural
JSON format in [PROTOCOL.md](../PROTOCOL.md).

`Options` is a map with only these keys (unknown keys are rejected):

| Option | Default | Accepted range |
| --- | --- | --- |
| `max_effects` | 100 | 1–100 |
| `timeout_ms` | 5,000 | 1–300,000 |
| `max_heap_words` | 8,000,000 | 10,000–64,000,000 |

An invalid initial argument/options/UTF-8/byte budget returns `{error, Reason}`
without spawning. JSON input decoding/encoding, contract-schema, parse/typecheck
and evaluation checks run in the evaluator. The deadline starts at `start` and
includes startup, checking,
pure computation and time spent waiting for handlers. It is not reset per effect.

Monitor `pid(Run)` to detect an unexpected guardian failure. Normal terminal
events and the guardian's monitor `DOWN` are separate messages; after a terminal
event, clean up that monitor with `demonitor(Monitor, [flush])`. A guardian death
without a terminal event is an adapter failure, never an ordinary operation
error. The start call intentionally does not link the guardian to the owner.

## Owner events

```erlang
{eyg_json_bridge, Run, {effect_request, Id, Name, ArgumentJson}}
{eyg_json_bridge, Run, {result, {ok, ValueJson}}}
{eyg_json_bridge, Run, {result, {error, Reason}}}
{eyg_json_bridge, Run, {error, Reason}}
```

Names and JSON payloads are UTF-8 binaries. IDs start at 1, are sequential, and
only one request may be pending. `{result, {error, Reason}}` is a language/core
failure such as a type error or exhausted effect count. `{error, Reason}` is a
terminal adapter/protocol/lifecycle failure such as an invalid typed reply,
deadline, cancellation, worker crash or heap kill. Reasons are diagnostic text,
not a stable machine-readable error-code enumeration.

Reply success with a JSON binary, e.g. `{ok, <<"3">>}`, **not** a native integer
or a prewrapped EYG `Result`. Reply failure with plain UTF-8 error text. The
bridge creates EYG `Ok`/`Error` values itself. A malformed/wrong-typed reply or a
wrong/duplicate pending ID terminates the run; it never becomes catchable EYG
`Error`. A duplicate arriving after termination is simply a late message.

## Minimal Elixir example

This example uses a fixed, harmless `ReadCount` handler. In a real consumer,
authorize every request and perform domain-specific argument validation before
calling the backend.

```elixir
source = "match perform ReadCount({}) { Ok(n) -> {!int_add(n, input.delta)} Error(_) -> {0} }"
contracts = ~s({"ReadCount":{"argument":{"kind":"record","fields":{}},"result":{"kind":"integer"}}})
{:ok, run} = :eyg_json_bridge_beam.start(source, ~s({"delta":1}), contracts, %{timeout_ms: 5_000})
monitor = Process.monitor(:eyg_json_bridge_beam.pid(run))

receive do
  {:eyg_json_bridge, ^run, {:effect_request, 1, "ReadCount", "{}"}} ->
    :ok = :eyg_json_bridge_beam.reply(run, 1, {:ok, "3"})
  {:eyg_json_bridge, ^run, event} ->
    raise "unexpected terminal event: #{inspect(event)}"
  {:DOWN, ^monitor, :process, _, reason} ->
    raise "adapter exited: #{inspect(reason)}"
end

receive do
  {:eyg_json_bridge, ^run, {:result, {:ok, json}}} ->
    IO.puts(json) # 4
  {:eyg_json_bridge, ^run, event} ->
    raise "evaluation failed: #{inspect(event)}"
  {:DOWN, ^monitor, :process, _, reason} ->
    raise "adapter exited: #{inspect(reason)}"
end
Process.demonitor(monitor, [:flush])
```

A production owner should implement this as its ordinary receive/GenServer event
loop, dispatch every expected request, and distinguish terminal adapter failure
from application error. Do not block the owner indefinitely in a handler: the
evaluator deadline cannot interrupt or roll back the host's external operation.
If transferring work to another host process, keep the original owner alive
until the run terminates; ownership is not transferred with the handle.

## Limits and authority

- Acquired code/source plus input JSON (if supplied) plus contract JSON: at most
  1,000,000 bytes; encoded source: at most 1,000,000 bytes.
- `start/4` code: at most 64,000 UTF-16 code units, matching the Node encoder's
  source-text bound; acquired input JSON: at most 500,000 bytes (including its
  whitespace). Unlike Node's reserialized-input bound, native acquisition counts
  the supplied bytes. Input nesting is at most 32.
- Each effect name plus argument JSON: at most 64,000 bytes.
- Successful reply JSON: at most 64,000 bytes; application error text: 4,000.
- Final JSON: at most 12,000 bytes; evaluation diagnostics: at most 500 bytes.
- Cumulative acquired input payloads and emitted output payloads: 8,000,000
  bytes each. Native tuple metadata is not an NDJSON frame and is not counted.
- Contract shape limits, effect count, exact records and safe JSON integers are
  enforced by the same core used on JavaScript. Target-native intermediate
  arithmetic still differs as documented in the README.

`max_heap_words` configures OTP's per-process `max_heap_size` with killing enabled
and heap-kill logging disabled. It is checked during GC, is measured in machine
words, and is **not a total memory/RSS limit**: shared/off-heap binaries, the
host, guardian and VM resources are not bounded by it. The output byte checks
occur after the evaluator encodes the value. Native messages and the caller's
own allocations are not a hostile-node ingress boundary. The guardian's mailbox
is not a bounded queue. Treat the adapter and its handle as trusted-host APIs.

For hard memory/OS isolation, run a separate appropriately constrained BEAM VM
and manage its lifecycle outside this API. This adapter is not a hardened
hostile-code sandbox or an OTP application supervisor. A consumer may supervise
the owner; it must not automatically replay a terminated evaluation that could
have submitted mutations.

Cancellation, owner death, deadline or evaluator death stops EYG only. An
already-dispatched external operation may still finish. Keep operation receipts
and recovery in the consumer, terminate on uncertain submissions, and never
resume/retry those as ordinary catchable operation errors.

## Factorio rollout

1. Build/pin the BEAM source dependency and include its compiled applications in
   Factorio Control's Elixir release. Keep Node available until parity fixtures
   pass; no existing consumer checkout is modified here.
2. Replace the Port evaluator with `start/4` and owner event handling, passing
   the existing code and JSON-encoded input record. Alternatively, use `start/3`
   if Factorio already constructs prepared source including an input binding.
3. Dispatch the same game effect names and JSON arguments to existing handlers.
   Reply with JSON binaries and preserve action grants, receipts and recovery.
4. Monitor the guardian. On timeout/cancellation/crash or uncertain external
   submission, terminate the run without retrying the game mutation.
5. Run gameplay observation/action/error fixtures and the consumer's owner-death,
   cancellation and uncertain-operation tests before removing Node from that
   execution path. Test wide-integer differences explicitly.

For Pi or Factorio integrations needing binaries, arbitrary tags or unit-returning
standard effects, use native upstream EYG and `touch_grass`, as described in
[MIGRATION.md](MIGRATION.md). This adapter intentionally retains the restricted
JSON contract model.
