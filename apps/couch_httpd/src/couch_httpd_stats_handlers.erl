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

-module(couch_httpd_stats_handlers).
-include_lib("couch/include/couch_db.hrl").
-include("couch_httpd.hrl").

-export([handle_stats_req/1]).
-import(couch_httpd, [
    send_json/2, send_json/3, send_json/4, send_method_not_allowed/2,
    start_json_response/2, send_chunk/2, end_json_response/1,
    start_chunked_response/3, send_error/4
]).

handle_stats_req(#httpd{method='GET', path_parts=[_]}=Req) ->
    flush(Req),
    send_json(Req, couch_stats_aggregator:all(range(Req)));

handle_stats_req(#httpd{method='GET', path_parts=[_, _Mod]}) ->
    throw({bad_request, <<"Stat names must have exactly to parts.">>});

handle_stats_req(#httpd{method='GET',
                        path_parts=[_, <<"vm">>, <<"system">>]}=Req) ->
    flush(Req),
    send_vm_json(Req, couch_stats_vm:get_system_info());
handle_stats_req(#httpd{method='GET',
                        path_parts=[_, <<"vm">>, <<"memory">>]}=Req) ->
    flush(Req),
    send_vm_json(Req, couch_stats_vm:get_memory());
handle_stats_req(#httpd{method='GET',
                        path_parts=[_, <<"vm">>, <<"statistics">>]}=Req) ->
    flush(Req),
    send_vm_json(Req, couch_stats_vm:get_statistics());
handle_stats_req(#httpd{method='GET',
                        path_parts=[_, <<"vm">>, <<"process">>]}=Req) ->
    flush(Req),
    send_vm_json(Req, couch_stats_vm:get_process_info());
handle_stats_req(#httpd{method='GET',
                        path_parts=[_, <<"vm">>, <<"port">>]}=Req) ->
    flush(Req),
    send_vm_json(Req, couch_stats_vm:get_port_info());
handle_stats_req(#httpd{method='GET',
                        path_parts=[_, <<"vm">>, <<"ets">>]}=Req) ->
    flush(Req),
    send_vm_json(Req, couch_stats_vm:get_ets_info());
handle_stats_req(#httpd{method='GET',
                        path_parts=[_, <<"vm">>, <<"dets">>]}=Req) ->
    flush(Req),
    send_vm_json(Req, couch_stats_vm:get_dets_info());
handle_stats_req(#httpd{method='GET',
                        path_parts=[_, <<"httpd">>, <<"connections">>]}=Req) ->
    flush(Req),

    NbConns = lists:foldl(fun(Ref, Sum) ->
                    N = ranch_server:count_connections(Ref),
                    Sum + N
            end, 0, couch_httpd:get_bindings()),

    send_json(Req, {[{<<"httpd">>, {[{<<"connections">>, NbConns}]}}]});


handle_stats_req(#httpd{method='GET', path_parts=[_, Mod, Key]}=Req) ->
    flush(Req),
    Stats = couch_stats_aggregator:get_json({list_to_atom(binary_to_list(Mod)),
        list_to_atom(binary_to_list(Key))}, range(Req)),
    send_json(Req, {[{Mod, {[{Key, Stats}]}}]});

handle_stats_req(#httpd{method='GET', path_parts=[_, _Mod, _Key | _Extra]}) ->
    throw({bad_request, <<"Stat names must have exactly two parts.">>});

handle_stats_req(Req) ->
    send_method_not_allowed(Req, "GET").




send_vm_json(Req, Value) ->
    couch_httpd:initialize_jsonp(Req),
    Headers = [
        {"Content-Type", couch_httpd:negotiate_content_type(Req)},
        {"Cache-Control", "must-revalidate"}
    ],
    Body = [couch_httpd:start_jsonp(), mochijson2:encode(Value),
            couch_httpd:end_jsonp(), $\n],
    couch_httpd:send_response(Req, 200, Headers, Body).


range(Req) ->
    case couch_util:get_value("range", couch_httpd:qs(Req)) of
        undefined ->
            0;
        Value ->
            list_to_integer(Value)
    end.

flush(Req) ->
    case couch_util:get_value("flush", couch_httpd:qs(Req)) of
        "true" ->
            couch_stats_aggregator:collect_sample();
        _Else ->
            ok
    end.
