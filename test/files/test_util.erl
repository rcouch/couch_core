-module(test_util).

-export([init_code_path/0,
         build_file/1,
         source_file/1,
         config_files/0,
         run/2,
         request/3, request/4,
         rootdir/0,
         find_files/2]).


init_code_path() ->
    LibDir = filename:join([rootdir(), "lib"]),
    AllPath = process_path(filelib:wildcard("*", LibDir), LibDir, []),
    lists:foreach(fun(Path) ->
                code:add_patha(Path)
        end, AllPath).

source_file(Name) ->
    filename:join(rootdir(), Name).

build_file(Name) ->
    filename:join(rootdir(), Name).

config_files() ->
    [
        build_file("etc/default.ini"),
        build_file("etc/local.ini"),
        build_file("etc/random.ini")
    ].


rootdir() ->
    case os:getenv("ETAP_ROOTDIR") of
        false ->
            filename:join([os:getcwd(), "..", ".."]);
        Root ->
            Root
    end.

process_path([], _LibDir, Acc) ->
    lists:reverse(Acc);
process_path(["." | Rest], LibDir, Acc) ->
    process_path(Rest, LibDir, Acc);
process_path([".." | Rest], LibDir, Acc) ->
    process_path(Rest, LibDir, Acc);
process_path([PathName | Rest], LibDir, Acc) ->
    Path1 = filename:join([LibDir, PathName, "ebin"]),
    Acc1 = case filelib:is_dir(Path1) of
        true ->
            [Path1 | Acc];
        _ ->
            Acc
    end,
    process_path(Rest, LibDir, Acc1).

run(Plan, Fun) ->
    test_util:init_code_path(),
    etap:plan(Plan),
    case (catch Fun()) of
        ok ->
            timer:sleep(500),
            etap:end_tests();
        Other ->
            etap:diag(io_lib:format("Test died abnormally:~n~p", [Other])),
            timer:sleep(500),
            etap:bail(Other)
    end,
    ok.


request(Url, Headers, Method) ->
    request(Url, Headers, Method, []).

request(Url, Headers, Method, Body) ->
    request(Url, Headers, Method, Body, 3).

request(_Url, _Headers, _Method, _Body, 0) ->
    {error, request_failed};
request(Url, Headers, Method, Body, N) ->
    case code:is_loaded(ibrowse) of
    false ->
        {ok, _} = ibrowse:start();
    _ ->
        ok
    end,
    case ibrowse:send_req(Url, Headers, Method, Body) of
    {ok, Code0, RespHeaders, RespBody0} ->
        Code = list_to_integer(Code0),
        RespBody = iolist_to_binary(RespBody0),
        {ok, Code, RespHeaders, RespBody};
    {error, {'EXIT', {normal, _}}} ->
        % Connection closed right after a successful request that
        % used the same connection.
        request(Url, Headers, Method, Body, N - 1);
    Error ->
        Error
    end.


find_files(Dir, Regex) ->
    find_files(Dir, Regex, true).

find_files(Dir, Regex, Recursive) ->
    filelib:fold_files(Dir, Regex, Recursive,
                       fun(F, Acc) -> [F | Acc] end, []).


