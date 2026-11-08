-module(beam_adapter_test).
-include_lib("eunit/include/eunit.hrl").

contracts() -> <<"{\"ReadCount\":{\"argument\":{\"kind\":\"record\",\"fields\":{}},\"result\":{\"kind\":\"integer\"}}}">>.
read_code() -> <<"match perform ReadCount({}) { Ok(n) -> {!int_add(n, 1)} Error(_) -> {42} }">>.
pure_loop() -> <<"let loop = !fix((self) -> { (_) -> { self({}) } })\nloop({})">>.

start(Code) -> start(Code, #{}).
start(Code, Options) ->
    {ok, Run} = eyg_json_bridge_beam:start(Code, contracts(), Options),
    Run.

next(Run) ->
    receive {eyg_json_bridge, Run, Event} -> Event
    after 3000 -> error({missing_event, Run}) end.

assert_stopped(Run) ->
    Monitor = monitor(process, eyg_json_bridge_beam:pid(Run)),
    receive {'DOWN', Monitor, process, _, _} -> ok
    after 1000 -> error(guardian_not_stopped) end.

worker(Run) ->
    {links, [Worker]} = process_info(eyg_json_bridge_beam:pid(Run), links),
    Worker.

pure_and_typed_effect_test() ->
    Pure = start(<<"{number: !int_add(2, 3), yes: True({}), items: [1, 2]}">>),
    {result, {ok, Json}} = next(Pure),
    ?assertEqual(#{<<"number">> => 5, <<"yes">> => true, <<"items">> => [1, 2]}, json:decode(Json)),
    assert_stopped(Pure),
    Run = start(read_code()),
    ?assertEqual({effect_request, 1, <<"ReadCount">>, <<"{}">>}, next(Run)),
    Worker = worker(Run),
    ok = eyg_json_bridge_beam:reply(Run, 1, {ok, <<"3">>}),
    ?assertEqual({result, {ok, <<"4">>}}, next(Run)),
    ?assertNot(is_process_alive(Worker)),
    assert_stopped(Run).

json_input_encoding_test() ->
    Inputs = iolist_to_binary(json:encode(#{<<"n">> => 41, <<"text">> => <<"quote \" slash \\ newline\n", 16#1f642/utf8>>,
                           <<"items">> => [true, false], <<"record">> => #{<<"v">> => -7}})),
    {ok, Run} = eyg_json_bridge_beam:start(<<"{n: !int_add(input.n, 1), text: input.text, items: input.items, record: input.record}">>,
                                           Inputs, <<"{}">>, #{}),
    {result, {ok, Json}} = next(Run),
    Expected = maps:put(<<"n">>, 42, json:decode(Inputs)),
    ?assertEqual(Expected, json:decode(Json)),
    assert_stopped(Run),
    lists:foreach(fun(BadInputs) ->
        {ok, Bad} = eyg_json_bridge_beam:start(<<"input">>, BadInputs, <<"{}">>, #{}),
        ?assertMatch({error, _}, next(Bad)),
        assert_stopped(Bad)
    end, [<<"[]">>, <<"null">>, <<"{">>, <<"{\"x\":null}">>, <<"{\"x\":1.5}">>,
          <<"{\"x\":9007199254740992}">>, <<"{\"bad-key\":1}">>, <<"{\"bad\\n\":1}">>]),
    Deep = iolist_to_binary([<<"{\"x\":" >>, lists:duplicate(33, <<"[">>), <<"0">>, lists:duplicate(33, <<"]">>), <<"}">>]),
    {ok, TooDeep} = eyg_json_bridge_beam:start(<<"input">>, Deep, <<"{}">>, #{}),
    ?assertMatch({error, _}, next(TooDeep)),
    assert_stopped(TooDeep),
    ?assertMatch({error, _}, eyg_json_bridge_beam:start(binary:copy(<<"x">>, 64001), <<"{}">>, <<"{}">>, #{})),
    ?assertMatch({error, _}, eyg_json_bridge_beam:start(<<"0">>, binary:copy(<<" ">>, 500001), <<"{}">>, #{})),
    ?assertMatch({error, _}, eyg_json_bridge_beam:start(<<" ">>, <<"{}">>, <<"{}">>, #{})).

operation_error_is_catchable_test() ->
    Run = start(read_code()),
    {effect_request, 1, _, _} = next(Run),
    ok = eyg_json_bridge_beam:reply(Run, 1, {error, <<"denied">>}),
    ?assertEqual({result, {ok, <<"42">>}}, next(Run)),
    assert_stopped(Run).

bad_start_test() ->
    lists:foreach(fun({Source, Contracts, Options}) ->
        ?assertMatch({error, _}, eyg_json_bridge_beam:start(Source, Contracts, Options))
    end, [
        {not_binary, <<"{}">>, #{}}, {<<255>>, <<"{}">>, #{}},
        {<<"0">>, <<255>>, #{}}, {<<"0">>, <<"{}">>, []},
        {<<"0">>, <<"{}">>, #{typo => true}},
        {<<"0">>, <<"{}">>, #{timeout_ms => 0}},
        {<<"0">>, <<"{}">>, #{timeout_ms => 300001}},
        {<<"0">>, <<"{}">>, #{max_heap_words => 1}},
        {<<"0">>, <<"{}">>, #{max_effects => 101}},
        {binary:copy(<<"0">>, 1000001), <<"{}">>, #{}}
    ]).

contracts_and_evaluation_failures_test() ->
    {ok, Bad} = eyg_json_bridge_beam:start(<<"0">>, <<"{\"bad\":{}}">>, #{}),
    ?assertMatch({error, _}, next(Bad)),
    assert_stopped(Bad),
    lists:foreach(fun(Code) ->
        Run = start(Code),
        ?assertMatch({result, {error, _}}, next(Run)),
        assert_stopped(Run)
    end, [<<"let =">>, <<"perform Shell(\"bad\")">>, <<"perform ReadCount(1)">>, <<"9007199254740992">>]).

malformed_replies_stop_test() ->
    lists:foreach(fun({Id, Reply}) ->
        Run = start(read_code()),
        {effect_request, 1, _, _} = next(Run),
        Worker = worker(Run),
        ok = eyg_json_bridge_beam:reply(Run, Id, Reply),
        ?assertMatch({error, _}, next(Run)),
        ?assertNot(is_process_alive(Worker)),
        assert_stopped(Run)
    end, [
        {2, {ok, <<"3">>}}, {1.0, {ok, <<"3">>}},
        {1, {ok, <<"\"3\"">>}}, {1, {ok, <<"9007199254740992">>}},
        {1, {ok, <<"1.5">>}}, {1, {ok, <<"not json">>}},
        {1, {ok, <<255>>}}, {1, {ok, 3}}, {1, {wat, <<"3">>}},
        {1, {ok, binary:copy(<<"0">>, 64001)}},
        {1, {error, binary:copy(<<"x">>, 4001)}}
    ]).

exact_record_reply_test() ->
    Contracts = <<"{\"Observe\":{\"argument\":{\"kind\":\"record\",\"fields\":{}},\"result\":{\"kind\":\"record\",\"fields\":{\"count\":{\"kind\":\"integer\"}}}}}">>,
    {ok, Run} = eyg_json_bridge_beam:start(<<"perform Observe({})">>, Contracts, #{}),
    {effect_request, 1, _, _} = next(Run),
    eyg_json_bridge_beam:reply(Run, 1, {ok, <<"{\"count\":1,\"extra\":2}">>}),
    ?assertMatch({error, _}, next(Run)),
    assert_stopped(Run).

sequential_effects_and_budget_test() ->
    Code = <<"let _ = perform ReadCount({})\nmatch perform ReadCount({}) { Ok(n) -> {n} Error(_) -> {0} }">>,
    Run = start(Code),
    {effect_request, 1, _, _} = next(Run),
    eyg_json_bridge_beam:reply(Run, 1, {ok, <<"2">>}),
    {effect_request, 2, _, _} = next(Run),
    eyg_json_bridge_beam:reply(Run, 2, {ok, <<"7">>}),
    ?assertEqual({result, {ok, <<"7">>}}, next(Run)),
    assert_stopped(Run),
    Limited = start(Code, #{max_effects => 1}),
    {effect_request, 1, _, _} = next(Limited),
    eyg_json_bridge_beam:reply(Limited, 1, {ok, <<"2">>}),
    ?assertEqual({result, {error, <<"effect budget exceeded">>}}, next(Limited)),
    assert_stopped(Limited).

cancel_pending_test() ->
    Run = start(read_code()),
    {effect_request, 1, _, _} = next(Run),
    Worker = worker(Run),
    eyg_json_bridge_beam:cancel(Run),
    ?assertEqual({error, <<"BEAM evaluation cancelled">>}, next(Run)),
    ?assertNot(is_process_alive(Worker)),
    assert_stopped(Run),
    %% Late replies/cancels cannot resurrect a completed run or emit another result.
    eyg_json_bridge_beam:reply(Run, 1, {ok, <<"3">>}),
    eyg_json_bridge_beam:cancel(Run),
    receive {eyg_json_bridge, Run, _} -> error(duplicate_terminal) after 20 -> ok end.

deadline_during_pure_evaluation_test() ->
    Run = start(pure_loop(), #{timeout_ms => 100}),
    ?assertEqual({error, <<"BEAM evaluation deadline exceeded">>}, next(Run)),
    assert_stopped(Run).

cancel_during_pure_evaluation_test() ->
    %% Begin with an effect to prove that parsing/typechecking finished, then loop.
    Code = <<"let _ = perform ReadCount({})\n", (pure_loop())/binary>>,
    Run = start(Code),
    {effect_request, 1, _, _} = next(Run),
    Worker = worker(Run),
    eyg_json_bridge_beam:reply(Run, 1, {ok, <<"3">>}),
    timer:sleep(20),
    eyg_json_bridge_beam:cancel(Run),
    ?assertEqual({error, <<"BEAM evaluation cancelled">>}, next(Run)),
    ?assertNot(is_process_alive(Worker)),
    assert_stopped(Run).

owner_death_cleans_up_test() ->
    Parent = self(),
    Owner = spawn(fun() ->
        Run = start(read_code()),
        {effect_request, 1, _, _} = next(Run),
        Parent ! {owned_run, Run, worker(Run)},
        receive stop -> ok end
    end),
    receive {owned_run, Run, Worker} ->
        WorkerMonitor = monitor(process, Worker),
        exit(Owner, kill),
        receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok after 1000 -> error(orphan_worker) end,
        assert_stopped(Run)
    after 3000 -> error(owner_start_failed) end.

guardian_death_kills_evaluator_test() ->
    Run = start(read_code()),
    {effect_request, 1, _, _} = next(Run),
    Worker = worker(Run),
    Monitor = monitor(process, Worker),
    exit(eyg_json_bridge_beam:pid(Run), kill),
    receive {'DOWN', Monitor, process, Worker, _} -> ok after 1000 -> error(orphan_worker) end,
    assert_stopped(Run).

guardian_shutdown_cleans_up_test() ->
    Run = start(read_code()),
    {effect_request, 1, _, _} = next(Run),
    Worker = worker(Run),
    exit(eyg_json_bridge_beam:pid(Run), shutdown),
    ?assertEqual({error, <<"BEAM guardian received exit signal">>}, next(Run)),
    ?assertNot(is_process_alive(Worker)),
    assert_stopped(Run).

worker_crash_is_terminal_test() ->
    Run = start(read_code()),
    {effect_request, 1, _, _} = next(Run),
    exit(worker(Run), kill),
    ?assertEqual({error, <<"BEAM evaluator exited without a result">>}, next(Run)),
    assert_stopped(Run).

deadline_while_waiting_for_handler_test() ->
    Run = start(read_code(), #{timeout_ms => 100}),
    {effect_request, 1, _, _} = next(Run),
    Worker = worker(Run),
    ?assertEqual({error, <<"BEAM evaluation deadline exceeded">>}, next(Run)),
    ?assertNot(is_process_alive(Worker)),
    assert_stopped(Run).

owner_death_during_pure_evaluation_test() ->
    Parent = self(),
    Owner = spawn(fun() ->
        Run = start(<<"let _ = perform ReadCount({})\n", (pure_loop())/binary>>),
        {effect_request, 1, _, _} = next(Run),
        eyg_json_bridge_beam:reply(Run, 1, {ok, <<"3">>}),
        Parent ! {looping_run, Run, worker(Run)},
        receive stop -> ok end
    end),
    receive {looping_run, Run, Worker} ->
        timer:sleep(20),
        WorkerMonitor = monitor(process, Worker),
        exit(Owner, kill),
        receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok after 1000 -> error(orphan_loop) end,
        assert_stopped(Run)
    after 3000 -> error(owner_start_failed) end.

duplicate_pending_reply_test() ->
    Run = start(<<"let _ = perform ReadCount({})\nperform ReadCount({})">>),
    {effect_request, 1, _, _} = next(Run),
    Guardian = eyg_json_bridge_beam:pid(Run),
    true = erlang:suspend_process(Guardian),
    try
        eyg_json_bridge_beam:reply(Run, 1, {ok, <<"3">>}),
        eyg_json_bridge_beam:reply(Run, 1, {ok, <<"3">>})
    after erlang:resume_process(Guardian) end,
    ?assertEqual({error, <<"Invalid pending effect response">>}, next(Run)),
    assert_stopped(Run).

heap_limit_terminates_run_test() ->
    Code = <<"let _ = perform ReadCount({})\nlet loop = !fix((self) -> { (xs) -> { self([0, ..xs]) } })\nloop([])">>,
    Run = start(Code, #{max_heap_words => 100000}),
    %% Prove startup/checking finished before the allocation-heavy pure loop.
    {effect_request, 1, _, _} = next(Run),
    eyg_json_bridge_beam:reply(Run, 1, {ok, <<"3">>}),
    ?assertEqual({error, <<"BEAM evaluator exited without a result">>}, next(Run)),
    assert_stopped(Run).

output_limits_test() ->
    BigString = <<"\"", (binary:copy(<<"x">>, 12001))/binary, "\"">>,
    Run = start(BigString),
    ?assertEqual({error, <<"Result output budget exceeded">>}, next(Run)),
    assert_stopped(Run),
    Contracts = <<"{\"Print\":{\"argument\":{\"kind\":\"string\"},\"result\":{\"kind\":\"record\",\"fields\":{}}}}">>,
    Code = <<"perform Print(\"", (binary:copy(<<"x">>, 64001))/binary, "\")">>,
    {ok, LargeEffect} = eyg_json_bridge_beam:start(Code, Contracts, #{}),
    ?assertEqual({error, <<"Effect output budget exceeded">>}, next(LargeEffect)),
    assert_stopped(LargeEffect).

concurrent_runs_do_not_cross_test() ->
    A = start(read_code()), B = start(read_code()),
    {effect_request, 1, _, _} = next(A),
    {effect_request, 1, _, _} = next(B),
    %% An unrelated token cannot submit replies or cancel this run.
    eyg_json_bridge_beam:pid(A) ! {make_ref(), cancel},
    eyg_json_bridge_beam:reply(B, 1, {ok, <<"10">>}),
    eyg_json_bridge_beam:reply(A, 1, {ok, <<"20">>}),
    ?assertEqual({result, {ok, <<"11">>}}, next(B)),
    ?assertEqual({result, {ok, <<"21">>}}, next(A)),
    assert_stopped(A), assert_stopped(B).
