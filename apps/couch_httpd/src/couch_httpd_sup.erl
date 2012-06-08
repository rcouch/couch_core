% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_httpd_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1, config_change/2]).


%% Helper macro for declaring children of supervisor
%% -define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).
-define(CHILD(I), {I, {I, start_link, []}, permanent, brutal_kill, worker, [I]}).
-define(CHILD(I, M, A), {I, {M, start_link, A}, permanent, brutal_kill, worker,
                             [M]}).

start_link() ->
    {ok, Pid} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),

    %% register to config changes
    ok = couch_config:register(fun ?MODULE:config_change/2, Pid),

    %% announce HTTP uri
    couch_httpd:display_uris(),

    %% write uri file
    write_uri_file(),
    {ok, Pid}.

write_uri_file() ->
    Ip = couch_config:get("httpd", "bind_address"),
    Listeners = couch_httpd:get_listeners(),
    Uris = [couch_httpd_util:get_uri(Name, Ip) || Name <- Listeners],
    case couch_config:get("couchdb", "uri_file", null) of
    null -> ok;
    UriFile ->
        Lines = [begin case Uri of
            undefined -> [];
            Uri -> io_lib:format("~s~n", [Uri])
            end end || Uri <- Uris],
        case file:write_file(UriFile, Lines) of
        ok -> ok;
        {error, eacces} ->
            lager:info("Permission error when writing to URI file ~s", [UriFile]),
            throw({file_permission_error, UriFile});
        Error2 ->
            lager:info("Failed to write to URI file ~s: ~p~n", [UriFile, Error2]),
            throw(Error2)
        end
    end.

init([]) ->
    HTTP = couch_httpd:child_spec(http),
    VHost = ?CHILD(couch_httpd_vhost),
    AuthCache = ?CHILD(couch_auth_cache),
    HTTPs = case couch_config:get("ssl", "enable", "false") of
        "true" ->
            [couch_httpd:child_spec(https)];
        _ ->
            []
    end,
    {ok, {{one_for_one, 10, 3600}, [HTTP, VHost, AuthCache] ++ HTTPs}}.


config_change("httpd", "bind_address") ->
    restart_httpd();
config_change("httpd", "port") ->
    restart_listener(http);
config_change("httpd", "default_handler") ->
    restart_httpd();
config_change("httpd", "server_options") ->
    restart_httpd();
config_change("httpd", "socket_options") ->
    restart_httpd();
config_change("httpd", "authentication_handlers") ->
    couch_httpd:set_auth_handlers();
config_change("httpd_global_handlers", _) ->
    restart_httpd();
config_change("httpd_db_handlers", _) ->
    restart_httpd();
config_change("ssl", _) ->
    restart_listener(https).


restart_httpd() ->
    restart_listener(http),
    case couch_config:get("ssl", "enable", "false") of
        "true" ->
            restart_listener(https);
        _ ->
            ok
    end.

restart_listener(Ref) ->
    stop_listener(Ref),
    supervisor:start_child(?MODULE, couch_httpd:child_spec(Ref)).


stop_listener(Ref) ->
	case supervisor:terminate_child(?MODULE, {cowboy_listener_sup, Ref}) of
		ok ->
			supervisor:delete_child(?MODULE, {cowboy_listener_sup, Ref});
		{error, Reason} ->
			{error, Reason}
	end.

