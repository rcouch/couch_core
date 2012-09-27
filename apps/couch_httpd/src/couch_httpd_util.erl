-module(couch_httpd_util).

-export([get_uri/2, get_port/1, get_scheme/1]).


get_uri(Name, Ip) ->
    Port = get_port(Name),
    Scheme = get_scheme(Name),
    Scheme ++ "://" ++ Ip ++ ":" ++ integer_to_list(Port).

get_scheme(http) -> "http";
get_scheme(https) -> "https".


%% @doc Return the port used by a listener.
%%
-spec get_port(any()) -> inet:port_number().
get_port(Ref) ->
    ranch:get_port(Ref).
