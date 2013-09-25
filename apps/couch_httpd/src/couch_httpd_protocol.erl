%M% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%%% ex: ft=erlang ts=4 sw=4 et
%%%
%%% This file is part of rcouch released under the Apache 2 license.
%%% See the NOTICE for more information.


-module(couch_httpd_protocol).

-export([start_link/4]).
-export([init/4]).

-export([loop/1]).
-export([after_response/2, reentry/1]).
-export([new_request/3, call_body/2]).

-include("couch_httpd.hrl").

-define(REQUEST_RECV_TIMEOUT, 300000).   %% timeout waiting for request line
-define(HEADERS_RECV_TIMEOUT, 30000).    %% timeout waiting for headers

-define(MAX_HEADERS, 1000).
-define(DEFAULTS, [{name, ?MODULE},
                   {port, 8888}]).


-ifndef(gen_tcp_fix).
-define(R15B_GEN_TCP_FIX, {tcp_error,_,emsgsize} ->
        % R15B02 returns this then closes the socket, so close and exit
        terminate(State);
       ).
-else.
-define(R15B_GEN_TCP_FIX, ).
-endif.


%% @doc Start a mochiweb process
-spec start_link(any(), inet:socket(), module(), any()) -> {ok, pid()}.
start_link(Ref, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
    {ok, Pid}.


%% @private
-spec init(any(), inet:socket(), module(), any()) -> ok | none().
init(Ref, Socket, Transport, Opts) ->
    {loop, HttpLoop} = proplists:lookup(loop, Opts),
    ok = ranch:accept_ack(Ref),
    loop(#hstate{socket = Socket,
                 transport = Transport,
                 loop = HttpLoop}).

loop(#hstate{transport=Transport, socket=Socket}=State) ->
    ok = Transport:setopts(Socket, [{packet, http}]),
    request(State).

request(#hstate{transport=Transport, socket=Socket}=State) ->
    ok = Transport:setopts(Socket, [{active, once}]),
    receive
        {Protocol, _, {http_request, Method, Path, Version}}
               when Protocol == http orelse Protocol == ssl ->
            ok = Transport:setopts(Socket, [{packet, httph}]),
            headers(State, {Method, Path, Version}, [], 0);
        {Protocol, _, {http_error, "\r\n"}}
                when Protocol == http orelse Protocol == ssl ->
            request(State);
        {Protocol, _, {http_error, "\n"}}
                when Protocol == http orelse Protocol == ssl ->
            request(State);
        {tcp_closed, _} ->
            terminate(State);
        {ssl_closed, _} ->
            terminate(State);
        ?R15B_GEN_TCP_FIX
        _Other ->
            handle_invalid_request(State)
    after ?REQUEST_RECV_TIMEOUT ->
        terminate(State)
    end.

headers(#hstate{transport=Transport, socket=Socket}=State, Request,
        Headers, ?MAX_HEADERS) ->
    %% Too many headers sent, bad request.
    ok = Transport:setopts(Socket, [{packet, raw}]),
    handle_invalid_request(State, Request, Headers);
headers(#hstate{transport=Transport, socket=Socket, loop=Loop}=State, Request,
        Headers, HeaderCount) ->
    ok = Transport:setopts(Socket, [{active, once}]),
    receive
        {Protocol, _, http_eoh}
                when Protocol == http orelse Protocol == ssl ->
            Req = new_request(State, Request, Headers),
            catch(call_body(Loop, Req)),
            ?MODULE:after_response(Loop, Req);
        {Protocol, _, {http_header, _, Name, _, Value}}
                when Protocol == http orelse Protocol == ssl ->
            headers(State, Request, [{Name, Value} | Headers],
                    1 + HeaderCount);
        {tcp_closed, _} ->
            terminate(State);
        ?R15B_GEN_TCP_FIX
        _Other ->
            handle_invalid_request(State, Request, Headers)
    after ?HEADERS_RECV_TIMEOUT ->
        terminate(State)
    end.

call_body({M, F, A}, Req) ->
    erlang:apply(M, F, [Req | A]);
call_body({M, F}, Req) ->
    M:F(Req);
call_body(Body, Req) ->
    Body(Req).

-spec handle_invalid_request(term()) -> no_return().
handle_invalid_request(State) ->
    handle_invalid_request(State, {'GET', {abs_path, "/"}, {0,9}}, []),
    exit(normal).

-spec handle_invalid_request(term(), term(), term()) -> no_return().
handle_invalid_request(#hstate{transport=Transport, socket=Socket}=State,
                       Request, RevHeaders) ->
    Req = new_request(State, Request, RevHeaders),
    Req:respond({400, [], []}),
    Transport:close(Socket),
    exit(normal).

new_request(#hstate{transport=Transport, socket=Socket}=State,
            Request, RevHeaders) ->
    Transport:setopts(Socket, [{packet, raw}]),
    mochiweb:new_request({mochiweb_socket(State), Request,
                          lists:reverse(RevHeaders)}).


reentry(Body) ->
    fun (Req) ->
            ?MODULE:after_response(Body, Req)
    end.

after_response(Body, Req) ->
    {Transport, Socket} = case Req:get(socket) of
        {ssl, S} ->
            {ranch_ssl, S};
        S ->
            {ranch_tcp, S}
    end,

    case Req:should_close() of
        true ->
            mochiweb_socket:close(Socket),
            exit(normal);
        false ->
            Req:cleanup(),
            erlang:garbage_collect(),
            ?MODULE:loop(#hstate{transport=Transport,
                                 socket=Socket,
                                 loop=Body})
    end.


mochiweb_socket(#hstate{transport=Transport, socket=Socket}) ->
    case Transport of
        ranch_ssl ->
            {ssl, Socket};
        _ ->
            Socket
    end.


terminate(#hstate{transport=Transport, socket=Socket}) ->
    Transport:close(Socket),
    exit(normal).
