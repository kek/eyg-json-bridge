/// Bounded structural JSON bridge to upstream EYG. Effect implementations,
/// authorization and process lifetime belong to the embedding host.
import eyg/analysis/inference/levels_j/contextual as infer
import eyg/analysis/type_/isomorphic as t
import eyg/interpreter/break
import eyg/interpreter/expression as interpreter
import eyg/interpreter/state
import eyg/interpreter/value as v
import eyg/parser
import eyg_json_bridge/json as eyg_json
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

type Shape {
  Text
  Integer
  Boolean
  Items(Shape)
  Fields(List(#(String, Shape)))
}

type Contract {
  Contract(argument: Shape, reply: Shape)
}

pub opaque type Continuation {
  Continuation(
    reply: Shape,
    contracts: dict.Dict(String, Contract),
    env: state.Env(#(Int, Int)),
    stack: state.Stack(#(Int, Int)),
    remaining: Int,
  )
}

pub type Step {
  Done(value: String)
  Failed(error: String)
  Effect(name: String, argument: String, continuation: Continuation)
}

fn exact_fields(names) {
  use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
  case
    dict.size(fields) == list.length(names)
    && list.all(names, fn(name) { dict.has_key(fields, name) })
  {
    True -> decode.success(Nil)
    False -> decode.failure(Nil, "exact record")
  }
}

fn name_valid(name, first_chars, rest_chars) {
  case string.to_graphemes(name) {
    [] -> False
    [first, ..rest] ->
      string.contains(first_chars, first)
      && list.all(rest, fn(c) { string.contains(rest_chars, c) })
  }
}

fn shape_decoder(depth) -> decode.Decoder(Shape) {
  case depth > 8 {
    True -> decode.failure(Text, "contract depth at most 8")
    False -> {
      use kind <- decode.field("kind", decode.string)
      case kind {
        "string" -> {
          use _ <- decode.then(exact_fields(["kind"]))
          decode.success(Text)
        }
        "integer" -> {
          use _ <- decode.then(exact_fields(["kind"]))
          decode.success(Integer)
        }
        "boolean" -> {
          use _ <- decode.then(exact_fields(["kind"]))
          decode.success(Boolean)
        }
        "list" -> {
          use _ <- decode.then(exact_fields(["kind", "items"]))
          use inner <- decode.field(
            "items",
            decode.recursive(fn() { shape_decoder(depth + 1) }),
          )
          decode.success(Items(inner))
        }
        "record" -> {
          use _ <- decode.then(exact_fields(["kind", "fields"]))
          use fields <- decode.field(
            "fields",
            decode.dict(
              decode.string,
              decode.recursive(fn() { shape_decoder(depth + 1) }),
            ),
          )
          case
            dict.size(fields) <= 64
            && list.all(dict.keys(fields), fn(name) {
              name_valid(
                name,
                "abcdefghijklmnopqrstuvwxyz_",
                "abcdefghijklmnopqrstuvwxyz_0123456789",
              )
            })
          {
            True -> decode.success(Fields(dict.to_list(fields)))
            False -> decode.failure(Text, "at most 64 identifier fields")
          }
        }
        _ -> decode.failure(Text, "fixed structural type")
      }
    }
  }
}

fn shape_type(shape) {
  case shape {
    Text -> t.String
    Integer -> t.Integer
    Boolean -> t.boolean
    Items(inner) -> t.List(shape_type(inner))
    Fields(fields) ->
      t.record(list.map(fields, fn(field) { #(field.0, shape_type(field.1)) }))
  }
}

fn value_decoder(shape) -> decode.Decoder(state.Value(#(Int, Int))) {
  case shape {
    Text -> decode.map(decode.string, v.String)
    Integer -> {
      use n <- decode.then(decode.int)
      case n >= -9_007_199_254_740_991 && n <= 9_007_199_254_740_991 {
        True -> decode.success(v.Integer(n))
        False -> decode.failure(v.Integer(0), "safe integer")
      }
    }
    Boolean -> decode.map(decode.bool, v.bool)
    Items(inner) -> decode.map(decode.list(value_decoder(inner)), v.LinkedList)
    Fields(fields) -> {
      let fields_decoder =
        list.fold(fields, decode.success([]), fn(acc, field) {
          use fields <- decode.then(acc)
          use value <- decode.field(field.0, value_decoder(field.1))
          decode.success([#(field.0, value), ..fields])
        })
      use _ <- decode.then(
        exact_fields(list.map(fields, fn(field) { field.0 })),
      )
      decode.map(fields_decoder, fn(fields) { v.Record(dict.from_list(fields)) })
    }
  }
}

pub fn start(source: String, contracts_json: String, max_effects: Int) -> Step {
  let contract_decoder = {
    use _ <- decode.then(exact_fields(["argument", "result"]))
    use argument <- decode.field("argument", shape_decoder(0))
    use reply <- decode.field("result", shape_decoder(0))
    decode.success(Contract(argument, reply))
  }
  case
    json.parse(contracts_json, decode.dict(decode.string, contract_decoder))
  {
    Error(_) -> Failed("invalid effect contracts")
    Ok(contracts) -> start_contracts(source, contracts, max_effects)
  }
}

fn start_contracts(source, contracts, max_effects) {
  case
    dict.size(contracts) <= 32
    && max_effects >= 1
    && max_effects <= 100
    && list.all(dict.keys(contracts), fn(name) {
      name_valid(
        name,
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      )
    })
  {
    False -> Failed("invalid effect contracts or budget")
    True -> {
      let context =
        list.fold(dict.to_list(contracts), infer.pure(), fn(context, entry) {
          let #(name, Contract(argument, reply)) = entry
          infer.with_effect(
            context,
            name,
            shape_type(argument),
            t.result(shape_type(reply), t.String),
          )
        })
      case start_checked(source, context) {
        Error(reason) -> Failed(reason)
        Ok(next) -> drive(next, contracts, max_effects)
      }
    }
  }
}

// Private composition of upstream APIs, not an alternative embedding engine.
fn start_checked(source, context) {
  case parser.all_from_string(source) {
    Error(reason) -> Error("parse: " <> parser.format_error(reason, source))
    Ok(ast) ->
      case infer.check(context, ast) {
        infer.Lookup(_, _) -> Error("imports/references denied")
        infer.Done(analysis) ->
          case infer.all_errors(analysis) {
            [] -> Ok(interpreter.execute(ast, []))
            _ -> Error("type check failed (invalid type or unapproved effects)")
          }
      }
  }
}

fn drive(next, contracts, remaining) -> Step {
  case next {
    Ok(value) ->
      case eyg_json.encode(value, 0) {
        Ok(encoded) -> Done(json.to_string(encoded))
        Error(reason) -> Failed(reason)
      }
    Error(#(break.UnhandledEffect(name, argument), _, env, stack)) -> {
      case dict.get(contracts, name) {
        Error(_) -> Failed("effect denied: " <> name)
        Ok(Contract(argument_shape, reply)) ->
          case remaining <= 0 {
            True -> Failed("effect budget exceeded")
            False ->
              case eyg_json.encode(argument, 0) {
                Error(reason) -> Failed(reason)
                Ok(encoded) -> {
                  let argument = json.to_string(encoded)
                  case json.parse(argument, value_decoder(argument_shape)) {
                    Error(_) -> Failed("invalid typed effect argument")
                    Ok(_) ->
                      Effect(
                        name,
                        argument,
                        Continuation(
                          reply,
                          contracts,
                          env,
                          stack,
                          remaining - 1,
                        ),
                      )
                  }
                }
              }
          }
      }
    }
    Error(_) -> Failed("EYG evaluation failed (references denied)")
  }
}

pub fn resume(
  continuation: Continuation,
  successful: Bool,
  response: String,
) -> Step {
  let Continuation(reply, contracts, env, stack, remaining) = continuation
  let value = case successful {
    True ->
      json.parse(response, value_decoder(reply))
      |> result.map(v.ok)
      |> result.map_error(fn(_) { "invalid typed effect response" })
    False -> Ok(v.error(v.String(response)))
  }
  case value {
    Error(reason) -> Failed(reason)
    Ok(value) ->
      drive(interpreter.resume(value, env, stack), contracts, remaining)
  }
}

pub fn kind(step: Step) -> String {
  case step {
    Done(_) -> "done"
    Failed(_) -> "error"
    Effect(..) -> "effect"
  }
}

pub fn value(step: Step) -> String {
  case step {
    Done(value) -> value
    _ -> ""
  }
}

pub fn error(step: Step) -> String {
  case step {
    Failed(error) -> error
    _ -> ""
  }
}

pub fn effect(step: Step) -> String {
  case step {
    Effect(name, ..) -> name
    _ -> ""
  }
}

pub fn argument(step: Step) -> String {
  case step {
    Effect(argument:, ..) -> argument
    _ -> ""
  }
}

pub fn continuation(step: Step) -> Continuation {
  let assert Effect(continuation:, ..) = step
  continuation
}
