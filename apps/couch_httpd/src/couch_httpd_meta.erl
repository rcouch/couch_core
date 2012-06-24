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

-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_httpd/include/couch_httpd.hrl").

handle_req(#httpd{method='GET', path_parts=[DbName|_]}=Req, _Db) ->
    JsonObj = case couch_meta:get_meta(DbName) of
        {ok, Doc} ->
            couch_doc:to_json_obj(Doc, []);
        _ ->
            null
    end,
    couch_httpd:send_json(Req, 200, JsonObj);

handle_req(#httpd{method='PUT'}=_Req, _Db) ->
    ok;

handle_req(Req, _Db) ->
    couch_httpd:send_method_not_allowed(Req, "PUT,GET").


%% internal

