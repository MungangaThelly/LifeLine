-module(incident_store).
-behaviour(gen_server).

-export([start_link/1, create/1, list/0, get/1, mark_delivered/1, pending/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TABLE, lifeline_incidents).
-define(FILE, "incidents.dets").

start_link(DataDir) -> gen_server:start_link({local, ?MODULE}, ?MODULE, DataDir, []).
create(Incident) -> gen_server:call(?MODULE, {create, Incident}, 15000).
list() -> gen_server:call(?MODULE, list).
get(Id) -> gen_server:call(?MODULE, {get, Id}).
mark_delivered(Id) -> gen_server:call(?MODULE, {mark_delivered, Id}).
pending() -> gen_server:call(?MODULE, pending).

init(DataDir) ->
    ok = filelib:ensure_dir(filename:join(DataDir, "placeholder")),
    Path = filename:join(DataDir, ?FILE),
    case dets:open_file(?TABLE, [{file, Path}, {type, set}, {keypos, 1}, {repair, true}]) of
        {ok, ?TABLE} -> {ok, #{path => Path}};
        {error, Reason} -> {stop, {dets_open_failed, Reason}}
    end.

handle_call({create, Incident0}, _From, State) ->
    Id = maps:get(id, Incident0),
    case dets:lookup(?TABLE, Id) of
        [{Id, Existing}] -> {reply, {ok, Existing, duplicate}, State};
        [] ->
            Now = erlang:system_time(second),
            Incident = Incident0#{status => queued, created_at => Now, updated_at => Now,
                                  attempts => 0, last_error => null},
            case dets:insert(?TABLE, {Id, Incident}) of
                ok ->
                    case dets:sync(?TABLE) of
                        ok -> {reply, {ok, Incident, created}, State};
                        {error, Reason} -> {reply, {error, {sync_failed, Reason}}, State}
                    end;
                {error, Reason} -> {reply, {error, {write_failed, Reason}}, State}
            end
    end;
handle_call(list, _From, State) ->
    Incidents = dets:foldl(fun({_Id, Incident}, Acc) -> [Incident | Acc] end, [], ?TABLE),
    Sorted = lists:sort(fun(A, B) -> maps:get(created_at, A) >= maps:get(created_at, B) end, Incidents),
    {reply, Sorted, State};
handle_call({get, Id}, _From, State) ->
    Reply = case dets:lookup(?TABLE, Id) of [{Id, Incident}] -> {ok, Incident}; [] -> not_found end,
    {reply, Reply, State};
handle_call(pending, _From, State) ->
    Items = dets:foldl(fun({_Id, #{status := queued} = I}, Acc) -> [I | Acc]; (_, Acc) -> Acc end, [], ?TABLE),
    {reply, Items, State};
handle_call({mark_delivered, Id}, _From, State) ->
    Reply = case dets:lookup(?TABLE, Id) of
        [{Id, Incident}] ->
            Updated = Incident#{status => delivered, updated_at => erlang:system_time(second), last_error => null},
            case dets:insert(?TABLE, {Id, Updated}) of ok -> _ = dets:sync(?TABLE), {ok, Updated}; Error -> Error end;
        [] -> not_found
    end,
    {reply, Reply, State};
handle_call({delivery_failed, Id, Reason}, _From, State) ->
    Reply = case dets:lookup(?TABLE, Id) of
        [{Id, Incident}] ->
            Updated = Incident#{status => queued, attempts => maps:get(attempts, Incident, 0) + 1,
                                updated_at => erlang:system_time(second), last_error => printable(Reason)},
            case dets:insert(?TABLE, {Id, Updated}) of ok -> _ = dets:sync(?TABLE), {ok, Updated}; Error -> Error end;
        [] -> not_found
    end,
    {reply, Reply, State};
handle_call(_Request, _From, State) -> {reply, {error, bad_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> dets:close(?TABLE).
code_change(_OldVersion, State, _Extra) -> {ok, State}.

printable(Reason) when is_binary(Reason) -> Reason;
printable(Reason) -> iolist_to_binary(io_lib:format("~0p", [Reason])).
