-module(lifeline_api_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, [health]) ->
    reply_json(200, #{status => ok, service => lifeline, time => erlang:system_time(second)}, Req0);
init(Req0, [incidents]) ->
    Method = cowboy_req:method(Req0),
    handle_incidents(Method, Req0);
init(Req0, [incident]) ->
    Id = cowboy_req:binding(id, Req0),
    case incident_store:get(Id) of
        {ok, Incident} -> reply_json(200, Incident, Req0);
        not_found -> reply_json(404, #{error => not_found}, Req0)
    end.

handle_incidents(<<"GET">>, Req0) ->
    reply_json(200, #{incidents => incident_store:list()}, Req0);
handle_incidents(<<"POST">>, Req0) ->
    case cowboy_req:read_body(Req0, #{length => 65536, period => 5000}) of
        {ok, Body, Req1} -> create_incident(Body, Req1);
        {more, _Partial, Req1} -> reply_json(413, #{error => payload_too_large}, Req1)
    end;
handle_incidents(_Method, Req0) ->
    Req1 = cowboy_req:reply(405, #{<<"allow">> => <<"GET, POST">>}, Req0),
    {ok, Req1, undefined}.

create_incident(Body, Req0) ->
    try jsx:decode(Body, [return_maps]) of
        Input when is_map(Input) ->
            case validate(Input) of
                {ok, Incident} ->
                    case incident_store:create(Incident) of
                        {ok, Saved, created} -> delivery_queue:wake(), reply_json(202, Saved, Req0);
                        {ok, Saved, duplicate} -> reply_json(200, Saved, Req0);
                        {error, Reason} -> reply_json(500, #{error => storage_failed, detail => printable(Reason)}, Req0)
                    end;
                {error, Reason} -> reply_json(400, #{error => invalid_incident, detail => Reason}, Req0)
            end;
        _ -> reply_json(400, #{error => expected_object}, Req0)
    catch
        _:_ -> reply_json(400, #{error => invalid_json}, Req0)
    end.

validate(Input) ->
    Description = field(<<"description">>, Input),
    Location = field(<<"location">>, Input),
    Type = field(<<"type">>, Input),
    case {valid_text(Description, 3, 2000), valid_text(Location, 2, 300), valid_text(Type, 2, 80)} of
        {true, true, true} ->
            Id = normalize_id(field(<<"id">>, Input)),
            {ok, #{id => Id, description => trim(Description), location => trim(Location), type => trim(Type),
                   title => trim(Type), kind => trim(Type), source => source(Input),
                   severity => normalize_severity(field(<<"severity">>, Input)), assignee => <<>>, status => queued}};
        _ -> {error, <<"description, location, and type are required">>}
    end.

field(Key, Map) -> maps:get(Key, Map, <<>>).
valid_text(Value, Min, Max) when is_binary(Value), byte_size(Value) >= Min, byte_size(Value) =< Max ->
    string:trim(Value) =/= <<>>;
valid_text(_, _, _) -> false.
trim(Value) -> unicode:characters_to_binary(string:trim(unicode:characters_to_list(Value))).
normalize_severity(<<"critical">>) -> critical;
normalize_severity(<<"high">>) -> high;
normalize_severity(<<"medium">>) -> medium;
normalize_severity(<<"low">>) -> low;
normalize_severity(_) -> high.
source(Input) -> case field(<<"source">>, Input) of S when is_binary(S), byte_size(S) =< 80 -> S; _ -> <<"dashboard">> end.
normalize_id(Id) when is_binary(Id), byte_size(Id) >= 8, byte_size(Id) =< 80 -> Id;
normalize_id(_) -> <<"INC-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>.

reply_json(Code, Term, Req0) ->
    Body = jsx:encode(Term),
    Req1 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json; charset=utf-8">>,
                                    <<"cache-control">> => <<"no-store">>}, Body, Req0),
    {ok, Req1, undefined}.
printable(Reason) -> iolist_to_binary(io_lib:format("~0p", [Reason])).
