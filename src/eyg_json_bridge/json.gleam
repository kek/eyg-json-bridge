import eyg/interpreter/value as v
import gleam/dict
import gleam/json
import gleam/list
import gleam/result

pub fn encode(value: v.Value(a, b), depth: Int) -> Result(json.Json, String) {
  case depth > 64 {
    True -> Error("result too deeply nested")
    False ->
      case value {
        v.Integer(n) ->
          case n > 9_007_199_254_740_991 || n < -9_007_199_254_740_991 {
            True -> Error("result integer exceeds JavaScript safe range")
            False -> Ok(json.int(n))
          }
        v.String(s) -> Ok(json.string(s))
        v.LinkedList(items) -> {
          use entries <- result.try(
            list.try_map(items, fn(item) { encode(item, depth + 1) }),
          )
          Ok(json.preprocessed_array(entries))
        }
        v.Record(fields) -> {
          use entries <- result.try(
            list.try_map(dict.to_list(fields), fn(pair) {
              let #(key, item) = pair
              use encoded <- result.try(encode(item, depth + 1))
              Ok(#(key, encoded))
            }),
          )
          Ok(json.object(entries))
        }
        v.Tagged("True", _) -> Ok(json.bool(True))
        v.Tagged("False", _) -> Ok(json.bool(False))
        _ -> Error("result is not JSON-compatible")
      }
  }
}
