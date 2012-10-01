% 2012 (c) Nicolas R Dufour <nicolas.dufour@nemoworld.info>
%
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



-module(couch_httpd_meta).

-export([handle_req/2]).
-export([maybe_meta/1]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_httpd/include/couch_httpd.hrl").

handle_req(#httpd{method='GET', path_parts=[DbName|_]}=Req, _Db) ->
    JsonObj = case couch_meta:get_meta(DbName) of
        {ok, MetaValue} ->
            MetaValue;
        _ ->
            null
    end,
    couch_httpd:send_json(Req, 200, JsonObj);

handle_req(#httpd{method='PUT', path_parts=[DbName|_]}=Req, _Db) ->
    Meta = maybe_meta(Req),
    case Meta of
        {error, _} ->
            couch_httpd:send_error(Req, 400, <<"bad_request">>, <<"Bad 'meta' property">>);
        _ ->
            couch_meta:update_meta_doc(DbName, Meta),
            couch_httpd:send_json(Req, 200, [], {[{ok, true}]})
    end;

handle_req(Req, _Db) ->
    couch_httpd:send_method_not_allowed(Req, "PUT,GET").

maybe_meta(Req) ->
    Props = (catch couch_httpd:json_body_obj(Req)),
    case Props of
        {JsonProps} ->
            couch_httpd:validate_ctype(Req, "application/json"),
            case couch_util:get_value(<<"meta">>, JsonProps) of
                undefined ->
                    {error, wrong_meta};
                Meta ->
                    Meta 
            end; 
        {_,_} ->
            undefined
    end.

%% internal

