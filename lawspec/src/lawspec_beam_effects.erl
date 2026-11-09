%% @doc Lexically scoped ability evidence and typed failures on the BEAM.
%% The schema carries immutable handler choices; symbol identity is unchanged.
%% Stateful handlers and recordings belong to a monitored scope, so parallel
%% workers share their state and cancellation cannot leak handler processes.
%% ref:DEC-typed-core-boundary
-module(lawspec_beam_effects).
-behaviour(gen_server).
-export([
    with_scope/3,
    install/2,
    handler/2,
    stateless/1,
    stateful/3,
    retain/2,
    release/1,
    recording/2,
    perform/4,
    invoke/4,
    count_calls/4,
    shared/3,
    fail/1,
    raise_failure/2,
    native_raise/3,
    native_try/1,
    handler_state/2,
    set_handler_state/3,
    attempt/4,
    native_failures/4,
    match_exception/3,
    native_origin/0,
    origin/5,
    recover_handler/5,
    with_native_context/3,
    native_cell/1,
    native_read/1,
    native_write/2,
    typed_cell/2,
    typed_handler/1
]).
-export_type([context/0, handler_origin/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-opaque context() :: {lawspec_context, map(), reference()}.
-opaque handler_origin() ::
    none | {lawspec_handler_origin, binary(), map(), reference(), term(), [function()]}.

native_origin() -> none.

%% A native interface can cross back into a checked definition. Retaining its
%% logical handler lets that definition supply its current lexical context,
%% including any nested override of another ability used by a spec clause.
origin(Schema, Symbols, Ability, Handler, Operations) ->
    {lawspec_handler_origin, Ability, Schema, Symbols, Handler, Operations}.

recover_handler(
    {lawspec_handler_origin, Ability, _, Symbols, Handler, Operations},
    Ability,
    Symbols,
    Operations,
    _
) ->
    Handler;
recover_handler(none, _, _, _, Make) ->
    Make();
recover_handler({lawspec_handler_origin, Ability, _, Symbols, _, _}, Ability, Symbols, _, Make) ->
    Make();
recover_handler({lawspec_handler_origin, Ability, _, _, _, _}, Ability, _, _, _) ->
    erlang:error({lawspec, incompatible_handler_contexts});
recover_handler(_, Ability, _, _, _) ->
    erlang:error({lawspec, {invalid_handler_origin, Ability}}).

with_native_context(Origins, SchemaFactory, Body) ->
    Contexts = [{Schema, Symbols} || {lawspec_handler_origin, _, Schema, Symbols, _, _} <- Origins],
    {Schema, Symbols} =
        case Contexts of
            [] ->
                Fresh = make_ref(),
                {SchemaFactory(Fresh), Fresh};
            [{FirstSchema, FirstSymbols} | Rest] ->
                case lists:all(fun({_, S}) -> S =:= FirstSymbols end, Rest) of
                    true -> {FirstSchema, FirstSymbols};
                    false -> erlang:error({lawspec, incompatible_handler_contexts})
                end
        end,
    with_scope(Schema, #{}, fun(Scoped) -> Body(Scoped, Symbols) end).

%% Factories run inside the scope as well: a later factory failing releases
%% any state already allocated by earlier factories.
with_scope(Schema, Factories, Body) ->
    {ok, Scope} = gen_server:start(?MODULE, self(), []),
    Base = Schema#{lawspec_scope => Scope, lawspec_scopes => [Scope | scopes(Schema)]},
    Previous = put({?MODULE, scope}, Scope),
    try
        Handlers = maps:map(fun(_, Make) -> Make(Base) end, Factories),
        Body(install(Base, Handlers))
    after
        case Previous of
            undefined -> erase({?MODULE, scope});
            _ -> put({?MODULE, scope}, Previous)
        end,
        [erase(Key) || {{?MODULE, shared, S, _} = Key, _} <- get(), S =:= Scope],
        scope_call(Scope, close)
    end.

%% A handler of several abilities is made once in a scope and installed for
%% each of them, so every ability it answers shares its one state.
shared(#{lawspec_scope := Scope}, Key, Make) ->
    case get({?MODULE, shared, Scope, Key}) of
        undefined ->
            Handler = Make(),
            put({?MODULE, shared, Scope, Key}, Handler),
            Handler;
        Handler ->
            Handler
    end;
shared(_, _, Make) ->
    Make().

%% A shared resource keeps the handlers that acquired it until its final
%% release. Retain all lexical ancestors too: an inherited handler can belong
%% to an outer scope. Each lease is tied to a monitored holder, so a failed
%% resource owner cannot leave a scope and its state cells running forever.
%% ref:REQ-law-primitives ref:REQ-harness-units
retain(Schema, Holder) when is_pid(Holder) -> retain_scopes(scopes(Schema), Holder).

scopes(Schema) ->
    maps:get(
        lawspec_scopes,
        Schema,
        case maps:find(lawspec_scope, Schema) of
            {ok, Scope} -> [Scope];
            error -> []
        end
    ).

retain_scopes([], _) ->
    [];
retain_scopes([Scope | Rest], Holder) ->
    Lease = gen_server:call(Scope, {retain, Holder}, infinity),
    try
        [{Scope, Lease} | retain_scopes(Rest, Holder)]
    catch
        Class:Reason:Stack ->
            release([{Scope, Lease}]),
            erlang:raise(Class, Reason, Stack)
    end.

release(Leases) ->
    lists:foreach(fun({Scope, Lease}) -> scope_call(Scope, {release, Lease}) end, Leases).

%% Joining an unretained scope preserves with_scope's synchronous cleanup.
%% A retained scope closes when the last holder releases it or dies.
scope_call(Scope, Request) ->
    Monitor = monitor(process, Scope),
    try gen_server:call(Scope, Request, infinity) of
        closed ->
            receive
                {'DOWN', Monitor, process, Scope, _} -> ok
            end;
        retained ->
            ok
    catch
        exit:{noproc, _} -> ok;
        exit:{normal, _} -> ok
    after
        demonitor(Monitor, [flush])
    end.

%% Native production factories may allocate scoped state without receiving a
%% hidden argument. Only allocation uses this process-local scope; the cell
%% itself is a shareable process and all access is serialized by its server.
native_cell(Initial) ->
    case get({?MODULE, scope}) of
        Scope when is_pid(Scope) -> cell(#{lawspec_scope => Scope}, Initial);
        _ -> erlang:error({lawspec, missing_handler_scope})
    end.

native_read(Cell) -> lawspec_beam_handler:call(Cell, fun(Value) -> {Value, Value} end).
native_write(Cell, Value) -> lawspec_beam_handler:call(Cell, fun(_) -> {Value, Value} end).

install(Schema, Handlers) ->
    Schema#{lawspec_handlers => maps:merge(maps:get(lawspec_handlers, Schema, #{}), Handlers)}.

handler(Schema, Ability) ->
    case maps:find(Ability, maps:get(lawspec_handlers, Schema, #{})) of
        {ok, Handler} -> Handler;
        error -> erlang:error({lawspec, {missing_handler, Ability}})
    end.

stateless(Operations) -> {lawspec_handler, Operations}.

stateful(Schema, Initial, Operations) ->
    {lawspec_stateful, cell(Schema, Initial), Operations}.

%% A typed spec handler's state lives in a cell of the scope, as a dynamic
%% one's does; its operations run in the cell (lawspec_beam_fast).
typed_cell(Schema, Initial) -> cell(Schema, Initial).

%% The typed handler behind a native interface's origin, or a recording.
typed_handler({lawspec_handler_origin, _, _, _, Handler, _}) -> typed_handler(Handler);
typed_handler({lawspec_recording, _, Inner}) -> typed_handler(Inner);
typed_handler({lawspec_typed, _, _} = Handler) -> Handler;
typed_handler(_) -> erlang:error({lawspec, stateless_handler}).

recording(Schema, Handler) ->
    {lawspec_recording, cell(Schema, []), Handler}.

cell(#{lawspec_scope := Scope}, Initial) ->
    gen_server:call(Scope, {cell, Initial}, infinity);
cell(_, _) ->
    erlang:error({lawspec, missing_handler_scope}).

perform(Schema, Ability, Operation, Arguments) ->
    invoke(handler(Schema, Ability), Schema, Operation, Arguments).

invoke({lawspec_handler, Operations}, Schema, Operation, Arguments) ->
    Clause = operation(Operations, Operation),
    Clause(Schema, Arguments);
invoke({lawspec_stateful, Cell, Operations}, Schema, Operation, Arguments) ->
    Clause = operation(Operations, Operation),
    Path = maps:get(lawspec_effect_path, Schema, []),
    case lists:member(Cell, Path) of
        true ->
            erlang:error({lawspec, {recursive_handler_call, Operation}});
        false ->
            lawspec_beam_handler:call(Cell, fun(State) ->
                Clause(Schema#{lawspec_effect_path => [Cell | Path]}, Arguments, State)
            end)
    end;
invoke({lawspec_typed, Cell, Operations} = Handler, Schema, Operation, Arguments) ->
    Clause = operation(Operations, Operation),
    Path = maps:get(lawspec_effect_path, Schema, []),
    case lists:member(Cell, Path) of
        true -> erlang:error({lawspec, {recursive_handler_call, Operation}});
        false -> Clause(Schema#{lawspec_effect_path => [Cell | Path]}, Arguments, Handler)
    end;
invoke({lawspec_recording, Cell, Inner}, Schema, Operation, Arguments) ->
    %% Record the attempted call even if the wrapped operation aborts.
    lawspec_beam_handler:call(Cell, fun(Log) -> {ok, [{Operation, Arguments} | Log]} end),
    invoke(Inner, Schema, Operation, Arguments).

operation(Operations, Name) ->
    case maps:find(Name, Operations) of
        {ok, Clause} -> Clause;
        error -> erlang:error({lawspec, {missing_handler_operation, Name}})
    end.

count_calls(Schema, Ability, Operation, Arguments) ->
    case handler(Schema, Ability) of
        {lawspec_recording, Cell, _} ->
            Calls = lawspec_beam_handler:call(Cell, fun(Log) -> {Log, Log} end),
            length([
                ok
             || {Name, Values} <- Calls,
                Name =:= Operation,
                Arguments =:= any orelse lawspec_beam_scalar:equal(Values, Arguments)
            ]);
        _ ->
            erlang:error({lawspec, {recording_required, Ability}})
    end.

%% Native code uses fail/1 with its native failure value. The adapter's
%% declared Fail ability determines how that value crosses the boundary.
fail(Value) -> throw({lawspec_native_failure, Value}).
raise_failure(Ability, Value) -> throw({lawspec_failure, Ability, Value}).

%% The embedding forms: an operation's native failure as a value, and a spec
%% handler's state read and replaced in its native types.
native_try(Body) ->
    try
        {ok, Body()}
    catch
        throw:{lawspec_native_failure, Value} -> {error, Value}
    end.

handler_state({lawspec_handler_origin, _, Schema, _, Handler, _}, Convert) ->
    Cell = state_cell(Handler),
    Convert(Schema, lawspec_beam_handler:call(Cell, fun(State) -> {State, State} end));
handler_state(_, _) ->
    erlang:error({lawspec, stateless_handler}).

set_handler_state({lawspec_handler_origin, _, Schema, _, Handler, _}, Convert, Native) ->
    Cell = state_cell(Handler),
    Value = Convert(Schema, Native),
    lawspec_beam_handler:call(Cell, fun(_) -> {ok, Value} end),
    ok;
set_handler_state(_, _, _) ->
    erlang:error({lawspec, stateless_handler}).

state_cell({lawspec_stateful, Cell, _}) -> Cell;
state_cell({lawspec_recording, _, Inner}) -> state_cell(Inner);
state_cell(_) -> erlang:error({lawspec, stateless_handler}).

%% A spec handler seen through a native interface fails as native code does:
%% the logical failure crosses back as its native value.
native_raise(Ability, Convert, Body) ->
    try
        Body()
    catch
        throw:{lawspec_failure, Ability, Value} -> fail(Convert(Value))
    end.

attempt(Ability, Body, Right, Left) ->
    try Body() of
        Value -> Right(Value)
    catch
        throw:{lawspec_failure, Ability, Value} -> Left(Value)
    end.

%% Each optional native exception mapping returns no_match or {ok, Value}.
%% Existing typed failures pass through unchanged, including another ability.
native_failures(Ability, Convert, Body, Mappings) ->
    try
        Body()
    catch
        throw:{lawspec_native_failure, Native} ->
            raise_failure(Ability, Convert(Native));
        throw:{lawspec_failure, _, _} = Failure:Stack ->
            erlang:raise(throw, Failure, Stack);
        Class:Reason:Stack ->
            case mapped(Mappings, Class, Reason) of
                {ok, Value} -> raise_failure(Ability, Value);
                no_match -> erlang:raise(Class, Reason, Stack)
            end
    end.

mapped([], _, _) ->
    no_match;
mapped([Map | Rest], Class, Reason) ->
    case Map(Class, Reason) of
        no_match -> mapped(Rest, Class, Reason);
        {ok, _} = Found -> Found
    end.

%% Native mappings name an Elixir exception module or a tagged Erlang error
%% reason (also available to Gleam FFI code). They do not catch exits, throws,
%% or an unrelated error merely because its printed message contains the tag.
match_exception(
    {elixir, Module},
    error,
    #{'__struct__' := Module, '__exception__' := true} = Exception
) ->
    {ok, 'Elixir.Exception':message(Exception)};
match_exception({tag, Tag}, error, Tag) ->
    {ok, atom_to_binary(Tag, utf8)};
match_exception({tag, Tag}, error, Reason) when
    is_tuple(Reason),
    tuple_size(Reason) > 0,
    element(1, Reason) =:= Tag
->
    Message =
        case Reason of
            {Tag, Text} when is_binary(Text) -> Text;
            _ -> unicode:characters_to_binary(io_lib:format("~tp", [Reason]))
        end,
    {ok, Message};
match_exception(_, _, _) ->
    no_match.

init(Owner) ->
    {ok, #{owner => monitor(process, Owner), cells => #{}, leases => #{}, closing => false}}.

handle_call({cell, Initial}, _, State = #{cells := Cells}) ->
    {ok, Cell} = lawspec_beam_handler:start(self(), Initial),
    Monitor = monitor(process, Cell),
    {reply, Cell, State#{cells := Cells#{Monitor => Cell}}};
handle_call({retain, Holder}, _, State = #{leases := Leases}) ->
    Lease = monitor(process, Holder),
    {reply, Lease, State#{leases := Leases#{Lease => Holder}}};
handle_call({release, Lease}, _, State = #{leases := Leases}) ->
    demonitor(Lease, [flush]),
    finish_call(State#{leases := maps:remove(Lease, Leases)});
handle_call(close, _, State) ->
    finish_call(State#{closing := true}).

finish_call(#{closing := true, leases := Leases} = State) when map_size(Leases) =:= 0 ->
    {stop, normal, closed, State};
finish_call(State) ->
    {reply, retained, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info({'DOWN', Owner, process, _, _}, State = #{owner := Owner}) ->
    finish_info(State#{closing := true});
handle_info({'DOWN', Lease, process, _, _}, State = #{leases := Leases}) when
    is_map_key(Lease, Leases)
->
    finish_info(State#{leases := maps:remove(Lease, Leases)});
handle_info({'DOWN', Monitor, process, _, _}, State = #{cells := Cells}) ->
    {noreply, State#{cells := maps:remove(Monitor, Cells)}};
handle_info(_, State) ->
    {noreply, State}.

finish_info(#{closing := true, leases := Leases} = State) when map_size(Leases) =:= 0 ->
    {stop, normal, State};
finish_info(State) ->
    {noreply, State}.

terminate(_, #{cells := Cells}) ->
    maps:foreach(fun(_, Cell) -> lawspec_beam_handler:stop(Cell) end, Cells).
