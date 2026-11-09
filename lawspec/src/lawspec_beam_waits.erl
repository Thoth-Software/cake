%% @doc Dependency tracking for stateful handler operations. A graph is shared
%% while cells are alive, including cells from nested or concurrent scopes.
%% It holds no handler values and exits when the last cell leaves. Losing the
%% tracker closes its monitored cells, so lost edges cannot cause a deadlock.
%% ref:DEC-typed-core-boundary
-module(lawspec_beam_waits).
-behaviour(gen_server).
-export([register/1, request/5, activate/3, complete/2, unregister/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

register(Cell) ->
    Graph =
        case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
            {ok, Pid} -> Pid;
            {error, {already_started, Pid}} -> Pid
        end,
    try gen_server:call(Graph, {register, Cell}, infinity) of
        ok -> Graph
    catch
        %% The previous last cell may have left between lookup and register.
        exit:{noproc, _} -> register(Cell);
        exit:{normal, _} -> register(Cell)
    end.

request(Graph, Token, Target, Caller, Context) ->
    gen_server:call(Graph, {request, Token, Target, Caller, Context}, infinity).
activate(Graph, Cell, Token) -> gen_server:call(Graph, {activate, Cell, Token}, infinity).
complete(Graph, Token) -> gen_server:call(Graph, {complete, Token}, infinity).
unregister(Graph, Cell) ->
    try
        gen_server:call(Graph, {unregister, Cell}, infinity)
    catch
        exit:_ -> ok
    end.

init([]) ->
    %% Also clean up if the very first registering caller dies during start.
    {ok, #{cells => #{}, cell_monitors => #{}, requests => #{}, callers => #{}}, 1000}.

handle_call({register, Cell}, _, State = #{cells := Cells, cell_monitors := Monitors}) ->
    Monitor = monitor(process, Cell),
    {reply, ok, State#{
        cells := Cells#{Cell => {Monitor, none}}, cell_monitors := Monitors#{Monitor => Cell}
    }};
handle_call(
    {request, Token, Target, Caller, Context},
    _,
    State = #{cells := Cells, requests := Requests, callers := Callers}
) ->
    Source = source(Context, Cells, Requests),
    case maps:is_key(Target, Cells) andalso not cyclic(Source, Target, Requests, Cells) of
        false ->
            {reply, {error, cyclic_handler_dependency}, State};
        true ->
            Monitor = monitor(process, Caller),
            {reply, ok, State#{
                requests := Requests#{Token => {Target, Caller, Monitor, Source}},
                callers := Callers#{Monitor => Token}
            }}
    end;
handle_call({activate, Cell, Token}, _, State = #{cells := Cells, requests := Requests}) ->
    case {maps:find(Cell, Cells), maps:find(Token, Requests)} of
        {{ok, {Monitor, none}}, {ok, {Cell, _, _, _}}} ->
            {reply, true, State#{cells := Cells#{Cell := {Monitor, Token}}}};
        _ ->
            {reply, false, State}
    end;
handle_call({complete, Token}, _, State) ->
    Updated = forget(Token, State),
    {reply, ok, Updated, idle(Updated)};
handle_call({unregister, Cell}, _, State) ->
    Updated = remove_cell(Cell, State),
    {reply, ok, Updated, idle(Updated)}.

handle_cast(_, State) -> {noreply, State, idle(State)}.

handle_info(
    {'DOWN', Monitor, process, _, _}, State = #{cell_monitors := Cells, callers := Callers}
) ->
    Updated =
        case {maps:find(Monitor, Cells), maps:find(Monitor, Callers)} of
            {{ok, Cell}, _} -> remove_cell(Cell, State);
            {_, {ok, Token}} -> forget(Token, State);
            _ -> State
        end,
    {noreply, Updated, idle(Updated)};
handle_info(timeout, State = #{cells := Cells}) when map_size(Cells) =:= 0 -> {stop, normal, State};
handle_info(_, State) ->
    {noreply, State, idle(State)}.

idle(#{cells := Cells}) when map_size(Cells) =:= 0 -> 0;
idle(_) -> infinity.

%% A task that outlives a completed operation no longer holds its cell.
source({Graph, Cell, Token}, Cells, Requests) when Graph =:= self(), Token =/= none ->
    case live_source({Cell, Token}, Cells, Requests) of
        Cell -> {Cell, Token};
        _ -> none
    end;
source(_, _, _) ->
    none.

cyclic(none, _, _, _) ->
    false;
cyclic({Source, _}, Target, Requests, Cells) ->
    Edges = maps:fold(
        fun(_, {To, Caller, _, From}, Acc) ->
            case is_process_alive(Caller) andalso live_source(From, Cells, Requests) of
                false -> Acc;
                none -> Acc;
                Cell -> Acc#{Cell => [To | maps:get(Cell, Acc, [])]}
            end
        end,
        #{},
        Requests
    ),
    reaches([Target], Source, Edges, #{}).

live_source({Cell, Token}, Cells, Requests) ->
    case {maps:find(Cell, Cells), maps:find(Token, Requests)} of
        {{ok, {_, Token}}, {ok, {Cell, Caller, _, _}}} ->
            case is_process_alive(Caller) of
                true -> Cell;
                false -> none
            end;
        _ ->
            none
    end;
live_source(none, _, _) ->
    none.

reaches([], _, _, _) ->
    false;
reaches([Target | _], Target, _, _) ->
    true;
reaches([Cell | Rest], Target, Edges, Seen) ->
    case maps:is_key(Cell, Seen) of
        true -> reaches(Rest, Target, Edges, Seen);
        false -> reaches(maps:get(Cell, Edges, []) ++ Rest, Target, Edges, Seen#{Cell => true})
    end.

%% Remove a dependency BEFORE returning its result. Removing it in the waiting
%% caller would leave a stale edge until that caller is scheduled again.
forget(Token, State = #{requests := Requests, callers := Callers, cells := Cells}) ->
    case maps:take(Token, Requests) of
        error ->
            State;
        {{Target, _, Monitor, _}, Rest} ->
            demonitor(Monitor, [flush]),
            UpdatedCells =
                case maps:find(Target, Cells) of
                    {ok, {CellMonitor, Token}} -> Cells#{Target := {CellMonitor, none}};
                    _ -> Cells
                end,
            State#{
                requests := Rest, callers := maps:remove(Monitor, Callers), cells := UpdatedCells
            }
    end.

remove_cell(Cell, State = #{cells := Cells, cell_monitors := Monitors, requests := Requests}) ->
    case maps:find(Cell, Cells) of
        error ->
            State;
        {ok, {Monitor, _}} ->
            demonitor(Monitor, [flush]),
            Cleared = lists:foldl(
                fun forget/2,
                State,
                [Token || {Token, {Target, _, _, _}} <- maps:to_list(Requests), Target =:= Cell]
            ),
            Cleared#{
                cells := maps:remove(Cell, maps:get(cells, Cleared)),
                cell_monitors := maps:remove(Monitor, Monitors)
            }
    end.
