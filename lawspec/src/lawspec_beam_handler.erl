%% @doc One spec handler's state, shared by all processes in its scope.
%% Clauses run outside the server so a blocked clause can still be cancelled.
%% ref:DEC-typed-core-boundary
-module(lawspec_beam_handler).
-behaviour(gen_server).
-export([start/2, call/2, in_place/2, in_place_tracked/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start(Owner, Initial) -> gen_server:start(?MODULE, {Owner, Initial}, []).

call(Handler, Update) ->
    Context = lawspec_beam_runtime:worker_context(),
    case gen_server:call(Handler, {update, make_ref(), Context, Update}, infinity) of
        {ok, Value} -> Value;
        {exception, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
    end.

%% A typed handler's operation runs in the cell's own process, so its state
%% is never copied: only Update and its result cross. A failure leaves the
%% state as it was. ref:DEC-typed-native-definitions
in_place(Handler, Update) ->
    case gen_server:call(Handler, {in_place, Update}, infinity) of
        {ok, Value} -> Value;
        {exception, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
    end.

%% The same for an operation that may call other handlers: it joins the
%% dependency graph, so a cycle of waiting operations still fails with
%% cyclic_handler_dependency instead of waiting forever.
in_place_tracked(Handler, Update) ->
    Context = lawspec_beam_runtime:worker_context(),
    Token = make_ref(),
    case
        lawspec_beam_waits:request(
            whereis(lawspec_beam_waits),
            Token,
            Handler,
            self(),
            proplists:get_value({?MODULE, context}, Context)
        )
    of
        ok -> ok;
        {error, Reason} -> erlang:error({lawspec, Reason})
    end,
    case gen_server:call(Handler, {in_place, Token, Update}, infinity) of
        {ok, Value} -> Value;
        {exception, Class, Reason2, Stack} -> erlang:raise(Class, Reason2, Stack)
    end.

stop(Handler) ->
    try
        gen_server:stop(Handler, normal, infinity)
    catch
        exit:noproc -> ok
    end.

init({Owner, Initial}) ->
    process_flag(trap_exit, true),
    Graph = lawspec_beam_waits:register(self()),
    {ok, #{
        owner => monitor(process, Owner),
        value => Initial,
        graph => Graph,
        graph_monitor => monitor(process, Graph),
        active => none,
        waiting => queue:new()
    }}.

handle_call({in_place, Token, Update}, _, State = #{value := Value, graph := Graph}) ->
    Cell = self(),
    _ = lawspec_beam_waits:activate(Graph, Cell, Token),
    Previous = put({?MODULE, context}, {Graph, Cell, Token}),
    Reply =
        try Update(Value) of
            {Result, NewState} -> {{ok, Result}, NewState};
            Other -> {{exception, error, {lawspec, {invalid_handler_result, Other}}, []}, Value}
        catch
            Class:Reason:Stack -> {{exception, Class, Reason, Stack}, Value}
        after
            case Previous of
                undefined -> erase({?MODULE, context});
                _ -> put({?MODULE, context}, Previous)
            end,
            lawspec_beam_waits:complete(Graph, Token)
        end,
    {Answer, Next} = Reply,
    {reply, Answer, State#{value := Next}};
handle_call({in_place, Update}, _, State = #{value := Value}) ->
    try Update(Value) of
        {Reply, NewState} -> {reply, {ok, Reply}, State#{value := NewState}};
        Other -> {reply, {exception, error, {lawspec, {invalid_handler_result, Other}}, []}, State}
    catch
        Class:Reason:Stack -> {reply, {exception, Class, Reason, Stack}, State}
    end;
handle_call({update, Token, Context, Update}, From = {Caller, _}, State = #{graph := Graph}) ->
    Origin = proplists:get_value({?MODULE, context}, Context),
    case lawspec_beam_waits:request(Graph, Token, self(), Caller, Origin) of
        ok ->
            Entry = {From, monitor(process, Caller), Token, Context, Update},
            {noreply, next(State#{waiting := queue:in(Entry, maps:get(waiting, State))})};
        {error, Reason} ->
            {reply, {exception, error, {lawspec, Reason}, []}, State}
    end.

handle_cast(_, State) -> {noreply, State}.

handle_info({'DOWN', Owner, process, _, _}, State = #{owner := Owner}) ->
    {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, Reason}, State = #{graph_monitor := Monitor}) ->
    {stop, {dependency_tracker_stopped, Reason}, State};
handle_info(
    {'DOWN', Monitor, process, Pid, Reason},
    State = #{active := {Pid, Monitor, From, CallerMonitor, Token}, graph := Graph}
) ->
    demonitor(CallerMonitor, [flush]),
    lawspec_beam_waits:complete(Graph, Token),
    %% A cancelled caller cannot commit a half-finished operation. Its DOWN
    %% signal may still be behind the worker's result in the mailbox.
    Updated =
        case is_process_alive(element(1, From)) of
            false ->
                State;
            true ->
                case Reason of
                    {lawspec_result, {ok, Value, NewState}} ->
                        gen_server:reply(From, {ok, Value}),
                        State#{value := NewState};
                    {lawspec_result, {exception, _, _, _} = Failure} ->
                        gen_server:reply(From, Failure),
                        State;
                    _ ->
                        gen_server:reply(
                            From, {exception, error, {lawspec, {handler_worker_failed, Reason}}, []}
                        ),
                        State
                end
        end,
    {noreply, next(Updated#{active := none})};
handle_info(
    {'DOWN', CallerMonitor, process, _, _},
    State = #{active := {Pid, Monitor, _, CallerMonitor, Token}, graph := Graph}
) ->
    cancel(Pid, Monitor),
    lawspec_beam_waits:complete(Graph, Token),
    {noreply, next(State#{active := none})};
handle_info({'DOWN', Monitor, process, _, _}, State) ->
    Waiting = queue:filter(fun({_, M, _, _, _}) -> M =/= Monitor end, maps:get(waiting, State)),
    {noreply, State#{waiting := Waiting}};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, State) ->
    case maps:get(active, State) of
        none ->
            ok;
        {Pid, Monitor, _, CallerMonitor, _} ->
            cancel(Pid, Monitor),
            demonitor(CallerMonitor, [flush])
    end,
    lists:foreach(
        fun({_, M, _, _, _}) -> demonitor(M, [flush]) end,
        queue:to_list(maps:get(waiting, State))
    ),
    lawspec_beam_waits:unregister(maps:get(graph, State), self()).

next(State = #{active := none, waiting := Waiting, value := Value, graph := Graph}) ->
    case queue:out(Waiting) of
        {empty, _} ->
            State;
        {{value, {From, CallerMonitor, Token, Context, Update}}, Rest} ->
            case
                is_process_alive(element(1, From)) andalso
                    lawspec_beam_waits:activate(Graph, self(), Token)
            of
                false ->
                    demonitor(CallerMonitor, [flush]),
                    next(State#{waiting := Rest});
                true ->
                    %% The link prevents a worker leaking if the server itself
                    %% is killed; the monitor carries its result and stack.
                    Cell = self(),
                    WorkerContext = lists:keystore({?MODULE, context}, 1, Context, {
                        {?MODULE, context}, {Graph, Cell, Token}
                    }),
                    {Pid, Monitor} = spawn_opt(
                        fun() ->
                            Result =
                                try
                                    case
                                        lawspec_beam_runtime:with_worker_context(
                                            WorkerContext, fun() -> Update(Value) end
                                        )
                                    of
                                        {Reply, NewState} ->
                                            {ok, Reply, NewState};
                                        Other ->
                                            erlang:error({lawspec, {invalid_handler_result, Other}})
                                    end
                                catch
                                    Class:Reason:Stack -> {exception, Class, Reason, Stack}
                                end,
                            exit({lawspec_result, Result})
                        end,
                        [link, monitor]
                    ),
                    State#{active := {Pid, Monitor, From, CallerMonitor, Token}, waiting := Rest}
            end
    end;
next(State) ->
    State.

cancel(Pid, Monitor) ->
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    end.
