%% Native BEAM process adapter for the structural JSON bridge.
%% The guardian never evaluates EYG: it can enforce deadlines during pure loops.
-module(eyg_json_bridge_beam).
-export([start/3, start/4, reply/3, cancel/1, pid/1]).
-export_type([run/0, event/0]).

-opaque run() :: {eyg_json_bridge_run, pid(), reference()}.
-type event() :: {effect_request, pos_integer(), binary(), binary()}
               | {result, {ok, binary()} | {error, binary()}}
               | {error, binary()}.

-spec start(binary(), binary(), map()) -> {ok, run()} | {error, binary()}.
start(Source, Contracts, Options) ->
    launch({prepared, Source}, Contracts, Options).

%% Code + JSON input record, corresponding to the Node adapter's code/inputs.
-spec start(binary(), binary(), binary(), map()) -> {ok, run()} | {error, binary()}.
start(Code, InputsJson, Contracts, Options) ->
    launch({inputs, Code, InputsJson}, Contracts, Options).

launch(Source, Contracts, Options) ->
    case valid_start(Source, Contracts, Options) of
        true ->
            Owner = self(),
            Ref = make_ref(),
            Deadline = erlang:monotonic_time(millisecond) + maps:get(timeout_ms, Options, 5000),
            Guardian = spawn(fun() -> init(Owner, Ref, Source, Contracts, Options, Deadline) end),
            {ok, {eyg_json_bridge_run, Guardian, Ref}};
        false -> {error, <<"Invalid source, contracts or BEAM options">>}
    end.

%% Monitor the guardian to detect unexpected adapter failure as well as events.
-spec pid(run()) -> pid().
pid({eyg_json_bridge_run, Guardian, _}) -> Guardian.

%% Replies are asynchronous. A malformed or out-of-sequence reply terminates the
%% run with an adapter error; it is never an EYG operation Error value.
-spec reply(run(), pos_integer(), {ok, binary()} | {error, binary()}) -> ok.
reply({eyg_json_bridge_run, Guardian, Ref}, Id, Reply) ->
    Guardian ! {Ref, reply, Id, Reply},
    ok.

-spec cancel(run()) -> ok.
cancel({eyg_json_bridge_run, Guardian, Ref}) ->
    Guardian ! {Ref, cancel},
    ok.

valid_start(Source, Contracts, Options) when is_binary(Contracts), is_map(Options) ->
    valid_source(Source)
    andalso source_bytes(Source) + byte_size(Contracts) =< 1000000
    andalso valid_utf8(Contracts)
    andalso lists:all(fun(K) -> lists:member(K, [max_effects, timeout_ms, max_heap_words]) end, maps:keys(Options))
    andalso bounded_int(maps:get(max_effects, Options, 100), 1, 100)
    andalso bounded_int(maps:get(timeout_ms, Options, 5000), 1, 300000)
    andalso bounded_int(maps:get(max_heap_words, Options, 8000000), 10000, 64000000);
valid_start(_, _, _) -> false.

valid_source({prepared, Source}) when is_binary(Source), byte_size(Source) =< 1000000 ->
    valid_utf8(Source);
valid_source({inputs, Code, Inputs}) when is_binary(Code), is_binary(Inputs),
                                          byte_size(Code) =< 256000, byte_size(Inputs) =< 500000 ->
    valid_utf8(Code) andalso valid_utf8(Inputs)
    andalso byte_size(unicode:characters_to_binary(Code, utf8, {utf16, big})) =< 128000
    andalso string:trim(Code) =/= <<>>;
valid_source(_) -> false.

source_bytes({prepared, Source}) -> byte_size(Source);
source_bytes({inputs, Code, Inputs}) -> byte_size(Code) + byte_size(Inputs).

bounded_int(N, Min, Max) -> is_integer(N) andalso N >= Min andalso N =< Max.
valid_utf8(Bin) -> is_binary(unicode:characters_to_binary(Bin, utf8, utf8)).

init(Owner, Ref, Source, Contracts, Options, Deadline) ->
    process_flag(trap_exit, true),
    OwnerMonitor = monitor(process, Owner),
    Guardian = self(),
    WorkRef = make_ref(),
    {Worker, WorkerMonitor} = spawn_opt(fun() ->
        evaluate(Guardian, WorkRef, Source, Contracts, maps:get(max_effects, Options, 100))
    end, [link, monitor, {message_queue_data, off_heap},
          {max_heap_size, #{size => maps:get(max_heap_words, Options, 8000000),
                            kill => true, error_logger => false}}]),
    loop(#{owner => Owner, ref => Ref, owner_monitor => OwnerMonitor,
           worker => Worker, worker_monitor => WorkerMonitor, work_ref => WorkRef,
           deadline => Deadline, pending => none,
           input_bytes => source_bytes(Source) + byte_size(Contracts), output_bytes => 0}).

loop(State = #{ref := Ref, work_ref := WorkRef, worker := Worker, worker_monitor := WorkerMonitor,
               owner_monitor := OwnerMonitor, deadline := Deadline}) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true -> finish(State, {error, <<"BEAM evaluation deadline exceeded">>});
        false ->
            receive
                {WorkRef, {effect_request, Id, Name, Argument} = Event} ->
                    Bytes = byte_size(Name) + byte_size(Argument),
                    case Bytes =< 64000 andalso maps:get(output_bytes, State) + Bytes =< 8000000 of
                        true ->
                            notify(State, Event),
                            loop(State#{pending := Id, output_bytes := maps:get(output_bytes, State) + Bytes});
                        false -> finish(State, {error, <<"Effect output budget exceeded">>})
                    end;
                {WorkRef, Event} -> finish(State, Event);
                {Ref, reply, Id, Reply} -> handle_reply(State, Id, Reply);
                {Ref, cancel} -> finish(State, {error, <<"BEAM evaluation cancelled">>});
                {'DOWN', OwnerMonitor, process, _, _} -> finish(State, silent);
                {'DOWN', WorkerMonitor, process, _, _} ->
                    %% No result was delivered. Includes max-heap kills and crashes.
                    finish(State#{worker_monitor := none}, {error, <<"BEAM evaluator exited without a result">>});
                {'EXIT', Worker, _} -> loop(State);
                {'EXIT', _, normal} -> loop(State);
                {'EXIT', _, _} -> finish(State, {error, <<"BEAM guardian received exit signal">>});
                _ -> loop(State)
            after Remaining ->
                finish(State, {error, <<"BEAM evaluation deadline exceeded">>})
            end
    end.

handle_reply(State = #{pending := Pending, input_bytes := Input}, Id, Reply) ->
    case is_integer(Id) andalso Id =:= Pending andalso valid_reply(Reply) of
        true ->
            Bytes = byte_size(element(2, Reply)),
            case Input + Bytes =< 8000000 of
                true ->
                    maps:get(worker, State) ! {maps:get(work_ref, State), Reply},
                    loop(State#{pending := none, input_bytes := Input + Bytes});
                false -> finish(State, {error, <<"Run input budget exceeded">>})
            end;
        false -> finish(State, {error, <<"Invalid pending effect response">>})
    end.

valid_reply({ok, Json}) when is_binary(Json), byte_size(Json) =< 64000 -> valid_utf8(Json);
valid_reply({error, Reason}) when is_binary(Reason), byte_size(Reason) =< 4000 -> valid_utf8(Reason);
valid_reply(_) -> false.

notify(#{owner := Owner, ref := Ref}, Event) ->
    Owner ! {eyg_json_bridge, {eyg_json_bridge_run, self(), Ref}, Event}.

finish(State = #{worker := Worker, worker_monitor := WorkerMonitor, owner_monitor := OwnerMonitor}, Event0) ->
    exit(Worker, kill),
    %% A terminal event certifies evaluator shutdown, not completion/rollback of
    %% external operations. Do not send it while the evaluator is still alive.
    case WorkerMonitor of
        none -> ok;
        _ -> receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok end
    end,
    demonitor(OwnerMonitor, [flush]),
    Event = case Event0 of
        {result, {ok, Json}} ->
            case byte_size(Json) =< 12000 andalso maps:get(output_bytes, State) + byte_size(Json) =< 8000000 of
                true -> Event0;
                false -> {error, <<"Result output budget exceeded">>}
            end;
        _ -> Event0
    end,
    case Event of silent -> ok; _ -> notify(State, Event) end.

evaluate(Guardian, WorkRef, Source, Contracts, MaxEffects) ->
    try
        Prepared = prepare_source(Source),
        Step = eyg_json_bridge:start(Prepared, Contracts, MaxEffects),
        case eyg_json_bridge:error(Step) of
            <<"invalid effect contracts">> -> Guardian ! {WorkRef, {error, <<"Invalid effect contracts">>}};
            <<"invalid effect contracts or budget">> -> Guardian ! {WorkRef, {error, <<"Invalid effect contracts or budget">>}};
            _ -> drive(Guardian, WorkRef, Step, 1)
        end
    catch
        throw:{input_error, Reason} -> Guardian ! {WorkRef, {error, Reason}};
        _:_ -> Guardian ! {WorkRef, {error, <<"BEAM evaluation failed">>}}
    end.

prepare_source({prepared, Source}) -> Source;
prepare_source({inputs, Code, InputsJson}) ->
    Inputs = try json:decode(InputsJson) catch _:_ -> input_error(<<"Invalid JSON inputs">>) end,
    case is_map(Inputs) of true -> ok; false -> input_error(<<"Inputs must be a record">>) end,
    Literal = literal(Inputs, 0),
    Source = iolist_to_binary([<<"let input = ">>, Literal, <<"\n">>, Code]),
    case byte_size(Source) =< 1000000 of
        true -> Source;
        false -> input_error(<<"Encoded source and inputs exceed 1 MB">>)
    end.

literal(_, Depth) when Depth > 32 -> input_error(<<"Input exceeds 32 nesting levels">>);
literal(Bin, _) when is_binary(Bin) -> json:encode(Bin);
literal(N, _) when is_integer(N), N >= -9007199254740991, N =< 9007199254740991 -> integer_to_binary(N);
literal(true, _) -> <<"True({})">>;
literal(false, _) -> <<"False({})">>;
literal(List, Depth) when is_list(List) ->
    [<<"[">>, lists:join(<<", ">>, [literal(V, Depth + 1) || V <- List]), <<"]">>];
literal(Map, Depth) when is_map(Map) ->
    Fields = [begin
        case re:run(Key, <<"\\A[a-z_][a-z0-9_]*\\z">>, [{capture, none}]) of
            match -> ok;
            nomatch -> input_error(<<"Unsupported input field">>)
        end,
        [Key, <<": ">>, literal(Value, Depth + 1)]
    end || {Key, Value} <- maps:to_list(Map)],
    [<<"{">>, lists:join(<<", ">>, Fields), <<"}">>];
literal(_, _) -> input_error(<<"Inputs require safe integers, strings, booleans, lists or records">>).

input_error(Reason) -> throw({input_error, Reason}).

drive(Guardian, WorkRef, Step, Id) ->
    case eyg_json_bridge:kind(Step) of
        <<"done">> -> Guardian ! {WorkRef, {result, {ok, eyg_json_bridge:value(Step)}}};
        <<"error">> -> Guardian ! {WorkRef, {result, {error, short_reason(eyg_json_bridge:error(Step))}}};
        <<"effect">> ->
            Guardian ! {WorkRef, {effect_request, Id, eyg_json_bridge:effect(Step), eyg_json_bridge:argument(Step)}},
            receive
                {WorkRef, Reply} ->
                    {Successful, Response} = case Reply of
                        {ok, Json} -> {true, Json};
                        {error, Reason} -> {false, Reason}
                    end,
                    Next = eyg_json_bridge:resume(eyg_json_bridge:continuation(Step), Successful, Response),
                    case eyg_json_bridge:error(Next) of
                        <<"invalid typed effect response">> ->
                            Guardian ! {WorkRef, {error, <<"Invalid typed effect response">>}};
                        _ -> drive(Guardian, WorkRef, Next, Id + 1)
                    end
            end
    end.

short_reason(Reason) ->
    Prefix = binary:part(Reason, 0, min(500, byte_size(Reason))),
    case unicode:characters_to_binary(Prefix, utf8, utf8) of
        Bin when is_binary(Bin) -> Bin;
        {_, Valid, _} -> Valid
    end.
