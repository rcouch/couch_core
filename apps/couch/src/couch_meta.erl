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
-export([maybe_delete_meta/1]).
-export([ensure_meta_db_exists/0]).

-include("couch_db.hrl").

create_default_meta_for_db(_DbName) ->
    {[]}.

maybe_create_meta(DbName, Meta) ->
    {ok, Db} = ensure_meta_db_exists(),
    JsonDoc = case Meta of
        undefined ->
            create_default_meta_for_db(DbName);
        _ ->
            Meta
    end,
    Doc = couch_doc:from_json_obj(JsonDoc),
    Doc2 = Doc#doc{id=DbName, revs={0, []}},
    ?LOG_INFO("Doc to be created for db ~p: ~p~n",[DbName, Doc2]),
    case (catch couch_db:update_doc(Db, Doc2, [full_commit])) of
        {ok, _} -> ok;
        Error ->
            ?LOG_INFO("Meta doc error (~s): ~p",[DbName, Error]),
            Error
    end.

maybe_delete_meta(DbName) ->
    {ok, Db} = ensure_meta_db_exists(),
    DocId = DbName,
    case couch_db:open_doc(Db, DocId, []) of
        {ok, Doc} ->
            Doc2 = Doc#doc{deleted=true},
            case (catch couch_db:update_doc(Db, Doc2, [full_commit])) of
                {ok, _} -> ok;
                Error ->
                    ?LOG_INFO("Can't delete the meta doc for the db: ~p. Error: ~p!~n", [DbName, Error]),
                    Error
            end;
        Error ->
            ?LOG_INFO("Can't find the meta doc for Db: ~p. Error: ~p!~n", [DbName, Error]),
            Error
    end. 

%update_doc_with(DocBody, KVs) ->
%    lists:foldl(
%        fun({K, undefined}, Body) ->
%                lists:keydelete(K, 1, Body);
%            ({K, _V} = KV, Body) ->
%                lists:keystore(K, 1, Body, KV) 
%        end,
%        DocBody,
%        KVs
%    ).

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
