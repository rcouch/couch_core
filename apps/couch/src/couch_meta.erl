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

-module(couch_meta).

-export([maybe_create_meta/2]).
-export([ensure_meta_db_exists/0]).

-include("couch_db.hrl").

maybe_create_meta(DbName, undefined) ->
    ensure_meta_db_exists(),
    io:format("No meta for db ~p, let's go on...~n", [DbName]),
    ok;
maybe_create_meta(DbName, Meta) ->
    io:format("Meta to create! with value: ~p for dbname ~p~n", [Meta, DbName]),
    {ok, Db} = ensure_meta_db_exists(),
    Doc = couch_doc:from_json_obj(Meta),
    Doc2 = Doc#doc{id=DbName, revs={0, []}},
    case (catch couch_db:update_doc(Db, Doc2, [full_commit])) of
        {ok, _} -> ok;
        Error ->
            ?LOG_INFO("Meta doc error (~s): ~p",[DbName, Error])
    end.

ensure_meta_db_exists() ->
    DbName = ?l2b(couch_config:get("meta", "db", "rc_dbs")),
    UserCtx = #user_ctx{roles = [<<"_admin">>, <<"rc_dbs">>]},
    case couch_db:open_int(DbName, [sys_db, {user_ctx, UserCtx}]) of
    {ok, Db} ->
        Db;
    _Error ->
        {ok, Db} = couch_db:create(DbName, [sys_db, {user_ctx, UserCtx}])
    end,
    {ok, Db}.
