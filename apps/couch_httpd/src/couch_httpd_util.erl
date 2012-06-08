-module(couch_httpd_util).

-export([get_uri/2, get_port/1, get_scheme/1]).


get_uri(Name, Ip) ->
    case get_port(Name) of
        {ok, Port} ->
            Scheme = get_scheme(Name),
            Scheme ++ "://" ++ Ip ++ ":" ++ integer_to_list(Port);
        _ ->
            undefined
    end.

get_scheme(http) -> "http";
get_scheme(https) -> "https".


%% @doc Return the port used by a listener.
%%
-spec get_port(any()) -> inet:port_number().
get_port(Ref) ->
    case ref_to_listener_pid(Ref) of
        false ->
            undefined;
        ListenerPid ->
            cowboy_listener:get_port(ListenerPid)
    end.


%% Internal.

-spec ref_to_listener_pid(any()) -> pid().
ref_to_listener_pid(Ref) ->
	Children = supervisor:which_children(couch_httpd_sup),
	{_, ListenerSupPid, _, _} = lists:keyfind(
		{cowboy_listener_sup, Ref}, 1, Children),
	ListenerSupChildren = supervisor:which_children(ListenerSupPid),
	{_, ListenerPid, _, _} = lists:keyfind(
		cowboy_listener, 1, ListenerSupChildren),
	ListenerPid.
