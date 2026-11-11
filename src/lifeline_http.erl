-module(lifeline_http).
-behaviour(gen_server).

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(Port) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Port, []).

init(Port) ->
    Dispatch = cowboy_router:compile([{'_', [
        {"/api/health", lifeline_api_handler, [health]},
        {"/api/incidents", lifeline_api_handler, [incidents]},
        {"/api/incidents/:id", lifeline_api_handler, [incident]},
        {"/", cowboy_static, {file, "index.html"}},
        {"/public/[...]", cowboy_static, {dir, "public"}}
    ]}]),
    case cowboy:start_clear(lifeline_listener, [{port, Port}], #{env => #{dispatch => Dispatch}}) of
        {ok, _Pid} -> {ok, #{port => Port}};
        {error, Reason} -> {stop, {http_listener_failed, Reason}}
    end.

handle_call(_Request, _From, State) -> {reply, {error, bad_request}, State}.
handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> cowboy:stop_listener(lifeline_listener).
code_change(_OldVersion, State, _Extra) -> {ok, State}.
