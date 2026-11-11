-module(lifeline_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    DataDir = application:get_env(lifeline, data_dir, "data"),
    Port = application:get_env(lifeline, port, 8080),
    Children = [
        #{id => incident_store, start => {incident_store, start_link, [DataDir]},
          restart => permanent, shutdown => 5000, type => worker, modules => [incident_store]},
        #{id => delivery_queue, start => {delivery_queue, start_link, []},
          restart => permanent, shutdown => 5000, type => worker, modules => [delivery_queue]},
        #{id => lifeline_http, start => {lifeline_http, start_link, [Port]},
          restart => permanent, shutdown => 10000, type => worker, modules => [lifeline_http]}
    ],
    {ok, {{one_for_one, 5, 10}, Children}}.
