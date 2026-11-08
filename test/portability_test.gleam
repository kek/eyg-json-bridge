import eyg_runtime as e
import gleam/io

const contracts =
  "{\"ReadCount\":{\"argument\":{\"kind\":\"record\",\"fields\":{}},\"result\":{\"kind\":\"integer\"}}}"

pub fn main() {
  let pure = e.start("!int_add(2, 3)", "{}", 100)
  let assert "done" = e.kind(pure)
  let assert "5" = e.value(pure)

  let code =
    "match perform ReadCount({}) { Ok(n) -> {!int_add(n, 1)} Error(_) -> {42} }"
  let first = e.start(code, contracts, 100)
  let assert "effect" = e.kind(first)
  let assert "ReadCount" = e.effect(first)
  let assert "{}" = e.argument(first)
  let done = e.resume(e.continuation(first), True, "3")
  let assert "done" = e.kind(done)
  let assert "4" = e.value(done)
  let denied = e.resume(e.continuation(first), False, "denied")
  let assert "42" = e.value(denied)
  let malformed = e.resume(e.continuation(first), True, "\"not an integer\"")
  let assert "error" = e.kind(malformed)

  let assert "error" = e.kind(e.start("perform Shell(\"bad\")", contracts, 100))
  let assert "error" = e.kind(e.start("perform ReadCount(1)", contracts, 100))
  let assert "error" = e.kind(e.start("let =", contracts, 100))
  let limited =
    e.start(
      "let _ = perform ReadCount({})\nperform ReadCount({})",
      contracts,
      1,
    )
  let exhausted = e.resume(e.continuation(limited), True, "3")
  let assert "effect budget exceeded" = e.error(exhausted)

  let shapes =
    "{\"Observe\":{\"argument\":{\"kind\":\"record\",\"fields\":{}},\"result\":{\"kind\":\"record\",\"fields\":{\"items\":{\"kind\":\"list\",\"items\":{\"kind\":\"integer\"}},\"complete\":{\"kind\":\"boolean\"}}}}}"
  let observe =
    e.start(
      "match perform Observe({}) { Ok(x) -> {x.complete} Error(_) -> {False({})} }",
      shapes,
      100,
    )
  let observed =
    e.resume(
      e.continuation(observe),
      True,
      "{\"items\":[1,2],\"complete\":true}",
    )
  let assert "true" = e.value(observed)
  io.println(
    "PASS: pure evaluation, typed continuation/resumption, catchable denial, invalid reply, ungranted effect, wrong argument, parse failure, effect budget, record/list/boolean reply",
  )

  let overflow =
    e.start("!int_to_string(!int_add(9007199254740991, 1))", "{}", 100)
  check_overflow(overflow)
  io.println(
    "intermediate wide integer: "
    <> e.kind(overflow)
    <> " / "
    <> e.value(overflow),
  )
  let wide = e.start("9007199254740992", "{}", 100)
  let assert "error" = e.kind(wide)
  io.println("wide integer: " <> e.kind(wide) <> " / " <> e.error(wide))
  let extra =
    e.resume(
      e.continuation(observe),
      True,
      "{\"items\":[1,2],\"complete\":true,\"extra\":1}",
    )
  let assert "error" = e.kind(extra)
  let unsafe = e.resume(e.continuation(first), True, "9007199254740992")
  let assert "error" = e.kind(unsafe)
  let assert "error" = e.kind(e.start("0", contracts, 0))
  let assert "error" = e.kind(e.start("0", contracts, 101))
  let assert "error" =
    e.kind(e.start(
      "0",
      "{\"bad\":{\"argument\":{\"kind\":\"integer\"},\"result\":{\"kind\":\"integer\"}}}",
      1,
    ))
  let assert "error" =
    e.kind(e.start(
      "0",
      "{\"ReadCount\":{\"argument\":{\"kind\":\"integer\"},\"result\":{\"kind\":\"integer\",\"extra\":true}}}",
      1,
    ))
  io.println(
    "PASS: direct core rejects extra record fields and unsafe reply integers",
  )
}

@target(javascript)
fn check_overflow(step) {
  let assert "error" = e.kind(step)
  Nil
}

@target(erlang)
fn check_overflow(step) {
  let assert "done" = e.kind(step)
  let assert "\"9007199254740992\"" = e.value(step)
  Nil
}
