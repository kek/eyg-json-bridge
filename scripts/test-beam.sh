#!/bin/sh
set -eu
gleam build --target erlang
erl -noshell -pa build/dev/erlang/*/ebin -eval 'case eunit:test(beam_adapter_test, [verbose]) of ok -> halt(0); _ -> halt(1) end.'
