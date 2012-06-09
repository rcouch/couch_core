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
-export([init/1]).


%% Helper macro for declaring children of supervisor
%% -define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).
-define(CHILD(I), {I, {I, start_link, []}, permanent, brutal_kill, worker, [I]}).
-define(CHILD(I, M, A), {I, {M, start_link, A}, permanent, brutal_kill, worker,
                             [M]}).

start_link() ->
    {ok, Pid} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
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
    Config = ?CHILD(couch_httpd_config),
    {ok, {{one_for_one, 10, 3600},
          [VHost, AuthCache, Config, HTTP] ++ HTTPs}}.
