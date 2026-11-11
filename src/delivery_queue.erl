-module(delivery_queue).
-behaviour(gen_server).

-export([start_link/0, wake/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(RETRY_MS, 5000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
wake() -> gen_server:cast(?MODULE, drain).
status() -> gen_server:call(?MODULE, status).

init([]) -> self() ! drain, {ok, #{in_flight => false, last_attempt => undefined}}.
handle_call(status, _From, State) -> {reply, State, State};
handle_call(_Request, _From, State) -> {reply, {error, bad_request}, State}.
handle_cast(drain, State) -> self() ! drain, {noreply, State};
handle_cast(_Message, State) -> {noreply, State}.
handle_info(drain, State) ->
    DeliveryUrl = application:get_env(lifeline, delivery_url, undefined),
    case DeliveryUrl of
        undefined -> erlang:send_after(?RETRY_MS, self(), drain), {noreply, State#{in_flight => false}};
        Url when is_list(Url); is_binary(Url) ->
            _ = inets:start(),
            Pending = incident_store:pending(),
            lists:foreach(fun(Incident) -> deliver(Url, Incident) end, Pending),
            erlang:send_after(?RETRY_MS, self(), drain),
            {noreply, State#{in_flight => false, last_attempt => erlang:system_time(second)}}
    end;
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

deliver(Url0, Incident) ->
    Url = case Url0 of B when is_binary(B) -> binary_to_list(B); L -> L end,
    Payload = jsx:encode(Incident),
    Headers = [{"idempotency-key", binary_to_list(maps:get(id, Incident))}],
    Request = {Url, Headers, "application/json", Payload},
    case httpc:request(post, Request, [{timeout, 5000}, {connect_timeout, 3000}], [{body_format, binary}]) of
        {ok, {{_Version, Code, _Reason}, _RespHeaders, _Body}} when Code >= 200, Code < 300 ->
            _ = incident_store:mark_delivered(maps:get(id, Incident)), ok;
        {ok, {{_Version, Code, _Reason}, _RespHeaders, Body}} ->
            mark_failed(Incident, {http_status, Code, Body});
        {error, Reason} -> mark_failed(Incident, Reason)
    end.

mark_failed(Incident, Reason) ->
    _ = gen_server:call(incident_store, {delivery_failed, maps:get(id, Incident), Reason}), ok.
