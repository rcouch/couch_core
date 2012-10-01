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

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([create_meta_doc/2]).
-export([delete_meta_doc/1]).
-export([get_meta_doc/1]).
-export([get_meta/1]).
-export([update_meta_doc/2]).
-export([ensure_meta_db_exists/0]).

-include("couch_db.hrl").

-define(SYS_DB_NAME, <<"rc_dbs">>).

-define(SYSTEM_KEY, <<"system">>).
-define(DB_KEY, <<"db">>).
-define(CREATED_KEY, <<"created">>).
-define(LAST_UPDATED_AT_KEY, <<"last_updated_at">>).
-define(COUCH_ID_KEY, <<"_id">>).
-define(COUCH_REV_KEY, <<"_rev">>).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

%% @doc create a new meta document for the given db.
create_meta_doc(DbName, Meta) ->
    % create the document
    Doc = new_meta_to_doc(DbName, Meta),
    ?LOG_DEBUG("Doc to be created for db ~p: ~p~n",[DbName, Doc]),

    %% then save it in both dbs
    case write_doc_in_db(DbName, Doc) of
        {ok, _} ->
            ok;
        Error ->
            Error
    end.

%% @doc delete meta doc for the given db.
delete_meta_doc(DbName) ->
    % In fact, at this point the db is dead and the doc with it.
    % Can be used as a hook point.
    ?LOG_DEBUG("Deleting Meta for Db ~p~n", [DbName]),
    ok.

%% @doc retrieve the meta doc.
get_meta_doc(DbName) ->
    {ok, Db} = get_db(DbName),
    DocId = meta_doc_id(DbName),
    couch_db:open_doc(Db, DocId, [ejson_body]).

%% @doc retrieve the json carrying only the meta information.
get_meta(DbName) ->
    case get_meta_doc(DbName) of
        {ok, Doc} ->
            Body = Doc#doc.body,
            MetaValue = remove_couch_props(Body),
            {ok, MetaValue};
        Error ->
            Error
    end.

%% @doc update the meta doc with the given Meta json.
update_meta_doc(DbName, Meta) ->
    ?LOG_DEBUG("Updating meta for Db ~p with: ~p~n", [DbName, Meta]),
    case get_meta_doc(DbName) of
        {ok, Doc} ->
            % updating the doc with new meta and our internal properties
            ?LOG_DEBUG("Body is: ~p~n", [Doc#doc.body]),
            UpdatedBodyWithNewMeta = update_body_with_new_meta(Doc#doc.body, Meta),
            UpdatedBodyWithSystem  = update_body_with_system(DbName, UpdatedBodyWithNewMeta),
            Doc2 = Doc#doc{body=UpdatedBodyWithSystem},

            % writing the new document back
            case write_doc_in_db(DbName, Doc2) of
                {ok, _} ->
                    ok;
                DbError ->
                    DbError
            end;
        Error ->
            ?LOG_INFO("Couldn't find the meta doc for the db ~p!", [DbName]),
            Error
    end.

ensure_meta_db_exists() ->
    DbName = ?l2b(couch_config:get("meta", "db", "rc_dbs")),
    case get_db(DbName) of
    {ok, Db} ->
        Db;
    _Error ->
        UserCtx = #user_ctx{roles = [<<"_admin">>, DbName]},
        {ok, Db} = couch_db:create(DbName, [sys_db, {user_ctx, UserCtx}])
    end,
    {ok, Db}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% @doc create a new meta document based on the given json meta.
new_meta_to_doc(DbName, Meta) ->
    JsonDoc = case Meta of
        undefined ->
            create_default_meta_for_db(DbName);
        _ ->
            Meta
    end,
    Doc = couch_doc:from_json_obj(JsonDoc),
    DocId = meta_doc_id(DbName),
    Doc#doc{id=DocId, revs={0, []}}.

%% @doc write the doc in the db with the given name.
write_doc_in_db(DbName, Doc) ->
    {ok, Db} = get_db(DbName),
    catch couch_db:update_doc(Db, Doc, [full_commit]).

%% @doc delete the meta doc in the given db name.
%delete_doc(DbName) ->
%    case get_doc(DbName) of
%        {ok, Doc} ->
%            Doc2 = Doc#doc{deleted=true},
%            {ok, Db} = get_db(DbName),
%            case (catch couch_db:update_doc(Db, Doc2, [full_commit])) of
%                {ok, _} -> ok;
%                DeleteError ->
%                    ?LOG_INFO("Couldn't delete the doc ~p in the Db ~p~n", [Doc, DbName]),
%                    DeleteError
%            end;
%        ReadError ->
%            ?LOG_INFO("Couldn't find the meta doc in the db ~p~n", [DbName]),
%            ReadError
%    end.

%% @doc compute the meta document id.
meta_doc_id(_DbName) ->
    %<< <<"_meta_">>/binary, DbName/binary >>.
    <<"_meta">>.

%% @doc creates a default set of properties for a meta document.
create_default_meta_for_db(DbName) ->
    Now = ?l2b(httpd_util:rfc1123_date()),
    {[
        { ?SYSTEM_KEY, create_default_system_property(DbName, Now) }
    ]}.

create_default_system_property(DbName, Timestamp) ->
    create_system_property(DbName, Timestamp, Timestamp).

create_system_property(DbName, CreateTimestamp, UpdateTimestamp) ->
    {[
        { ?DB_KEY,              DbName          },
        { ?CREATED_KEY,         CreateTimestamp },
        { ?LAST_UPDATED_AT_KEY, UpdateTimestamp }
    ]}.

get_db(DbName) ->
    UserCtx = #user_ctx{roles = [<<"_admin">>, DbName]},
    couch_db:open_int(DbName, [sys_db, {user_ctx, UserCtx}]).

remove_couch_props({Body}) ->
    UpdatedBody = lists:foldl(
        fun({?COUCH_ID_KEY, _}, Acc) ->
            % ignore couch id
            Acc;
           ({?COUCH_REV_KEY, _}, Acc) ->
            % ignore couch rev
            Acc;
           ({K, _V} = KV, Acc) ->
            lists:keystore(K, 1, Acc, KV)
        end,
        [],
        Body
    ),
    { UpdatedBody }.

update_body_with_new_meta({DocBody}, {KVs}) ->
    UpdatedBodyArray = lists:foldl(
        fun ({?SYSTEM_KEY, _}, Body) ->
                % ignoring any system property: reserved
                Body;
            ({?COUCH_ID_KEY, _}, Body) ->
                % ignoring _id: can't be changed
                Body;
            ({?COUCH_REV_KEY, _}, Body) ->
                % ignoring _rev: can't be changed
                Body;
            ({K, undefined}, Body) ->
                lists:keydelete(K, 1, Body);
            ({K, _V} = KV, Body) ->
                lists:keystore(K, 1, Body, KV) 
        end,
        DocBody,
        KVs
    ),
    { UpdatedBodyArray }.

update_property(Props, Key, Value) ->
    case lists:keymember(Key, 1, Props) of
        false ->
            lists:keystore(Key, 1, Props, {Key, Value});
        true  ->
            lists:keyreplace(Key, 1, Props, {Key, Value})
    end.

update_body_with_system(DbName, {Meta}) ->
    Now = ?l2b(httpd_util:rfc1123_date()),

    SystemPropValue = case lists:keyfind(?SYSTEM_KEY, 1, Meta) of
        { ?SYSTEM_KEY, {Props} } ->
            % updating the last_updated_at property with the timestamp
            UpdatedProps = update_property(Props, ?LAST_UPDATED_AT_KEY, Now),
            {UpdatedProps};
        _ ->
            ?LOG_INFO("No system property for meta doc ~p! Repairing with default values!~n", [DbName]),
            create_system_property(DbName, <<"unknown">>, Now)
    end,

    UpdatedMeta = update_property(Meta, ?SYSTEM_KEY, SystemPropValue),
    { UpdatedMeta }.

%% the end
