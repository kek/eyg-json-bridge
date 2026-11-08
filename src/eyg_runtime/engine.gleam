/// Shared checked execution boundary. Hosts select the effect context and own
/// handlers. Interpreter state is native, retained in the evaluator process.
import eyg/analysis/inference/levels_j/contextual as infer
import eyg/interpreter/expression as interpreter
import eyg/parser

pub fn start(source, context) {
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

/// Resume only with a host-validated native EYG value. This low-level API is
/// intended for trusted host adapters with richer types than the JSON protocol.
/// For structural JSON effects use eyg_runtime.start/resume instead.
pub fn resume(value, environment, continuation) {
  interpreter.resume(value, environment, continuation)
}
