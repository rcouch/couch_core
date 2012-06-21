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

-module(couch_changes).
-include("couch_changes.hrl").
-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_httpd/include/couch_httpd.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").

-export([handle_changes/3]).

% For the builtin filter _docs_ids, this is the maximum number
% of documents for which we trigger the optimized code path.
-define(MAX_DOC_IDS, 100).

-record(changes_acc, {
    db,
    seq,
    prepend,
    filter,
    callback,
    user_acc,
    resp_type,
    limit,
    include_docs,
    fields,
    conflicts,
    timeout,
    timeout_fun
}).

%% @type Req -> #httpd{} | {json_req, JsonObj()}
handle_changes(Args0, Req, Db0) ->
    #changes_args{
        style = Style,
        filter = FilterName,
        feed = Feed,
        dir = Dir,
        since = Since
    } = Args0,
    {FilterFun, FilterArgs} = make_filter_fun(FilterName, Style, Req, Db0),
    Args1 = Args0#changes_args{filter_fun = FilterFun,
                               filter_args = FilterArgs},
    Args = case FilterName of
        "_view" ->
            ViewArgs = parse_view_args(Req),
            Args1#changes_args{filter_view=parse_view_param(Req),
                               view_args=ViewArgs#mrargs{direction=Dir}};
        _ ->
            Args1
    end,

    Start = fun() ->
        {ok, Db} = couch_db:reopen(Db0),
        StartSeq = case Dir of
        rev ->
            couch_db:get_update_seq(Db);
        fwd ->
            Since
        end,
        {Db, StartSeq}
    end,
    % begin timer to deal with heartbeat when filter function fails
    case Args#changes_args.heartbeat of
    undefined ->
        erlang:erase(last_changes_heartbeat);
    Val when is_integer(Val); Val =:= true ->
        put(last_changes_heartbeat, now())
    end,

    case lists:member(Feed, ["continuous", "longpoll", "eventsource"]) of
    true ->
        fun(CallbackAcc) ->
            {Callback, UserAcc} = get_callback_acc(CallbackAcc),
            Notify = subscribe_changes_events(FilterName, Db0, Args),
            {Db, StartSeq} = Start(),
            UserAcc2 = start_sending_changes(Callback, UserAcc, Feed),
            {Timeout, TimeoutFun} = get_changes_timeout(Args, Callback),
            Acc0 = build_acc(Args, Callback, UserAcc2, Db, StartSeq,
                             <<"">>, Timeout, TimeoutFun),
            try
                keep_sending_changes(
                    Args#changes_args{dir=fwd},
                    Acc0,
                    true)
            after
                unsubscribe_changes_events(Notify, Db0, Args),
                get_rest_db_updated(ok) % clean out any remaining update messages
            end
        end;
    false ->
        fun(CallbackAcc) ->
            {Callback, UserAcc} = get_callback_acc(CallbackAcc),
            UserAcc2 = start_sending_changes(Callback, UserAcc, Feed),
            {Timeout, TimeoutFun} = get_changes_timeout(Args, Callback),
            {Db, StartSeq} = Start(),
            Acc0 = build_acc(Args#changes_args{feed="normal"}, Callback,
                             UserAcc2, Db, StartSeq, <<>>, Timeout, TimeoutFun),
            {ok, #changes_acc{seq = LastSeq, user_acc = UserAcc3}} =
                send_changes(
                    Args#changes_args{feed="normal"},
                    Acc0,
                    true),
            end_sending_changes(Callback, UserAcc3, LastSeq, Feed)
        end
    end.

subscribe_changes_events("_view", #db{name=DbName},
                         #changes_args{filter_view={DName, _VName}}) ->
    couch_mrview:subscribe(DbName, <<"_design/", DName/binary>>),
    nil;
subscribe_changes_events(_FilterName, Db0, _Args) ->
    Self = self(),
    {ok, Notify} = couch_db_update_notifier:start_link(
        fun({_, DbName}) when  Db0#db.name == DbName ->
            Self ! db_updated;
        (_) ->
            ok
        end
    ),
    Notify.

unsubscribe_changes_events(nil, #db{name=DbName},
                           #changes_args{filter_view={DName, _}}) ->
    couch_mrview:unsubscribe(DbName, <<"_design/", DName/binary>>);
unsubscribe_changes_events(Pid, _Db, _Args) ->
    couch_db_update_notifier:stop(Pid).

get_callback_acc({Callback, _UserAcc} = Pair) when is_function(Callback, 3) ->
    Pair;
get_callback_acc(Callback) when is_function(Callback, 2) ->
    {fun(Ev, Data, _) -> Callback(Ev, Data) end, ok}.

%% @type Req -> #httpd{} | {json_req, JsonObj()}
make_filter_fun([$_ | _] = FilterName, Style, Req, Db) ->
    builtin_filter_fun(FilterName, Style, Req, Db);
make_filter_fun(FilterName, Style, Req, Db) ->
    {os_filter_fun(FilterName, Style, Req, Db), []}.

os_filter_fun(FilterName, Style, Req, Db) ->
    case [list_to_binary(couch_httpd:unquote(Part))
            || Part <- string:tokens(FilterName, "/")] of
    [] ->
        fun(_Db2, #doc_info{revs=Revs}) ->
                builtin_results(Style, Revs)
        end;
    [DName, FName] ->
        DesignId = <<"_design/", DName/binary>>,
        DDoc = couch_httpd_db:couch_doc_open(Db, DesignId, nil, [ejson_body]),
        % validate that the ddoc has the filter fun
        #doc{body={Props}} = DDoc,
        couch_util:get_nested_json_value({Props}, [<<"filters">>, FName]),
        fun(Db2, DocInfo) ->
            DocInfos =
            case Style of
            main_only ->
                [DocInfo];
            all_docs ->
                [DocInfo#doc_info{revs=[Rev]}|| Rev <- DocInfo#doc_info.revs]
            end,
            Docs = [Doc || {ok, Doc} <- [
                    couch_db:open_doc(Db2, DocInfo2, [deleted, conflicts])
                        || DocInfo2 <- DocInfos]],
            {ok, Passes} = filter_docs(Req, Db2, DDoc, FName, Docs),
            [{[{<<"rev">>, couch_doc:rev_to_str({RevPos,RevId})}]}
                || {Pass, #doc{revs={RevPos,[RevId|_]}}}
                <- lists:zip(Passes, Docs), Pass == true]
        end;
    _Else ->
        throw({bad_request,
            "filter parameter must be of the form `designname/filtername`"})
    end.

parse_view_param({json_req, {Props}}) ->
    {Params} = couch_util:get_value(<<"query">>, Props),
    parse_view_param1(couch_util:get_value(<<"view">>, Params));

parse_view_param(Req) ->
    parse_view_param1(?l2b(couch_httpd:qs_value(Req, "view", ""))).

parse_view_param1(ViewParam) ->
    case re:split(ViewParam, <<"/">>) of
    [DesignName, ViewName] ->
        {DesignName, ViewName};
    _ ->
        throw({bad_request, "Invalid `view` parameter."})
    end.

builtin_filter_fun("_doc_ids", Style, {json_req, {Props}}, _Db) ->
    DocIds = couch_util:get_value(<<"doc_ids">>, Props),
    {filter_docids(DocIds, Style), DocIds};
builtin_filter_fun("_doc_ids", Style, #httpd{method='POST'}=Req, _Db) ->
    {Props} = couch_httpd:json_body_obj(Req),
    DocIds =  couch_util:get_value(<<"doc_ids">>, Props, nil),
    {filter_docids(DocIds, Style), DocIds};
builtin_filter_fun("_doc_ids", Style, #httpd{method='GET'}=Req, _Db) ->
    DocIds = ?JSON_DECODE(couch_httpd:qs_value(Req, "doc_ids", "null")),
    {filter_docids(DocIds, Style), DocIds};
builtin_filter_fun("_design", Style, _Req, _Db) ->
    {filter_designdoc(Style), []};
builtin_filter_fun("_view", Style, {json_req, {Props}}=Req, Db) ->
    {Params} = couch_util:get_value(<<"query">>, Props),
    FilterName = ?b2l(couch_util:get_value(<<"view_filter">>, Params,
                                           <<"">>)),
 	{os_filter_fun(FilterName, Style, Req, Db), []};
builtin_filter_fun("_view", Style, Req, Db) ->
    FilterName = couch_httpd:qs_value(Req, "view_filter", ""),
    {os_filter_fun(FilterName, Style, Req, Db), []};
builtin_filter_fun(_FilterName, _Style, _Req, _Db) ->
    throw({bad_request, "unknown builtin filter name"}).

filter_docids(DocIds, Style) when is_list(DocIds)->
    fun(_Db, #doc_info{id=DocId, revs=Revs}) ->
            case lists:member(DocId, DocIds) of
                true ->
                    builtin_results(Style, Revs);
                _ -> []
            end
    end;
filter_docids(_, _) ->
    throw({bad_request, "`doc_ids` filter parameter is not a list."}).

filter_designdoc(Style) ->
    fun(_Db, #doc_info{id=DocId, revs=Revs}) ->
            case DocId of
            <<"_design", _/binary>> ->
                    builtin_results(Style, Revs);
                _ -> []
            end
    end.

builtin_results(Style, [#rev_info{rev=Rev}|_]=Revs) ->
    case Style of
        main_only ->
            [{[{<<"rev">>, couch_doc:rev_to_str(Rev)}]}];
        all_docs ->
            [{[{<<"rev">>, couch_doc:rev_to_str(R)}]}
                || #rev_info{rev=R} <- Revs]
    end.

get_changes_timeout(Args, Callback) ->
    #changes_args{
        heartbeat = Heartbeat,
        timeout = Timeout,
        feed = ResponseType
    } = Args,
    DefaultTimeout = list_to_integer(
        couch_config:get("httpd", "changes_timeout", "60000")
    ),
    case Heartbeat of
    undefined ->
        case Timeout of
        undefined ->
            {DefaultTimeout, fun(UserAcc) -> {stop, UserAcc} end};
        infinity ->
            {infinity, fun(UserAcc) -> {stop, UserAcc} end};
        _ ->
            {lists:min([DefaultTimeout, Timeout]),
                fun(UserAcc) -> {stop, UserAcc} end}
        end;
    true ->
        {DefaultTimeout,
            fun(UserAcc) -> {ok, Callback(timeout, ResponseType, UserAcc)} end};
    _ ->
        {lists:min([DefaultTimeout, Heartbeat]),
            fun(UserAcc) -> {ok, Callback(timeout, ResponseType, UserAcc)} end}
    end.

start_sending_changes(_Callback, UserAcc, ResponseType)
        when ResponseType =:= "continuous"
        orelse ResponseType =:= "eventsource" ->
    UserAcc;
start_sending_changes(Callback, UserAcc, ResponseType) ->
    Callback(start, ResponseType, UserAcc).

build_acc(Args, Callback, UserAcc, Db, StartSeq, Prepend, Timeout, TimeoutFun) ->
    #changes_args{
        include_docs = IncludeDocs,
        fields = Fields,
        conflicts = Conflicts,
        limit = Limit,
        feed = ResponseType,
        filter_fun = FilterFun
    } = Args,
    #changes_acc{
        db = Db,
        seq = StartSeq,
        prepend = Prepend,
        filter = FilterFun,
        callback = Callback,
        user_acc = UserAcc,
        resp_type = ResponseType,
        limit = Limit,
        include_docs = IncludeDocs,
        fields = Fields,
        conflicts = Conflicts,
        timeout = Timeout,
        timeout_fun = TimeoutFun
    }.

send_changes(Args, Acc0, FirstRound) ->
    #changes_args{
        dir = Dir,
        filter = FilterName,
        filter_args = FilterArgs,
        filter_view = View,
        view_args = ViewArgs
    } = Args,
    #changes_acc{
        db = Db,
        seq = StartSeq
    } = Acc0,
    case FirstRound of
    true ->
        case FilterName of
        "_doc_ids" when length(FilterArgs) =< ?MAX_DOC_IDS ->
            send_changes_doc_ids(
                FilterArgs, Db, StartSeq, Dir, fun changes_enumerator/2, Acc0);
        "_design" ->
            send_changes_design_docs(
                Db, StartSeq, Dir, fun changes_enumerator/2, Acc0);
        "_view" ->
            send_changes_view(
                Db, View, StartSeq, ViewArgs, fun view_changes_enumerator/2, Acc0);
        _ ->
            couch_db:changes_since(
                Db, StartSeq, fun changes_enumerator/2, [{dir, Dir}], Acc0)
        end;
    false ->
        case FilterName of
        "_view" ->
            send_changes_view(
                Db, View, StartSeq, ViewArgs, fun view_changes_enumerator/2, Acc0);
        _ ->
            couch_db:changes_since(
                Db, StartSeq, fun changes_enumerator/2, [{dir, Dir}], Acc0)
        end
    end.


send_changes_doc_ids(DocIds, Db, StartSeq, Dir, Fun, Acc0) ->
    Lookups = couch_btree:lookup(Db#db.fulldocinfo_by_id_btree, DocIds),
    FullDocInfos = lists:foldl(
        fun({ok, FDI}, Acc) ->
            [FDI | Acc];
        (not_found, Acc) ->
            Acc
        end,
        [], Lookups),
    send_lookup_changes(FullDocInfos, StartSeq, Dir, Db, Fun, Acc0).


send_changes_design_docs(Db, StartSeq, Dir, Fun, Acc0) ->
    FoldFun = fun(FullDocInfo, _, Acc) ->
        {ok, [FullDocInfo | Acc]}
    end,
    KeyOpts = [{start_key, <<"_design/">>}, {end_key_gt, <<"_design0">>}],
    {ok, _, FullDocInfos} = couch_btree:fold(
        Db#db.fulldocinfo_by_id_btree, FoldFun, [], KeyOpts),
    send_lookup_changes(FullDocInfos, StartSeq, Dir, Db, Fun, Acc0).

send_changes_view(#db{name=DbName}, {DName, VName}, StartSeq, Args,
                  Fun, Acc0) ->
    DesignId = <<"_design/", DName/binary>>,
    case couch_mrview:view_changes_since(DbName, DesignId, VName, StartSeq, Fun,
                                         Args, Acc0) of
        {error, seqs_not_indexed} ->
            throw({bad_request, "Sequences are not indexed in " ++
                   binary_to_list(DesignId)});
        Resp ->
            Resp
    end.

send_lookup_changes(FullDocInfos, StartSeq, Dir, Db, Fun, Acc0) ->
    FoldFun = case Dir of
    fwd ->
        fun lists:foldl/3;
    rev ->
        fun lists:foldr/3
    end,
    GreaterFun = case Dir of
    fwd ->
        fun(A, B) -> A > B end;
    rev ->
        fun(A, B) -> A =< B end
    end,
    DocInfos = lists:foldl(
        fun(FDI, Acc) ->
            DI = couch_doc:to_doc_info(FDI),
            case GreaterFun(DI#doc_info.high_seq, StartSeq) of
            true ->
                [DI | Acc];
            false ->
                Acc
            end
        end,
        [], FullDocInfos),
    SortedDocInfos = lists:keysort(#doc_info.high_seq, DocInfos),
    FinalAcc = try
        FoldFun(
            fun(DocInfo, Acc) ->
                case Fun(DocInfo, Acc) of
                {ok, NewAcc} ->
                    NewAcc;
                {stop, NewAcc} ->
                    throw({stop, NewAcc})
                end
            end,
            Acc0, SortedDocInfos)
    catch
    throw:{stop, Acc} ->
        Acc
    end,
    case Dir of
    fwd ->
        {ok, FinalAcc#changes_acc{seq = couch_db:get_update_seq(Db)}};
    rev ->
        {ok, FinalAcc}
    end.

keep_sending_changes(Args, Acc0, FirstRound) ->
    #changes_args{
        feed = ResponseType,
        limit = Limit,
        db_open_options = DbOptions
    } = Args,

    case send_changes(Args#changes_args{dir=fwd}, Acc0, FirstRound) of
    {ok, ChangesAcc} ->
        #changes_acc{
            db = Db, callback = Callback, timeout = Timeout,
            timeout_fun = TimeoutFun, seq = EndSeq, prepend = Prepend2,
            user_acc = UserAcc2, limit = NewLimit
        } = ChangesAcc,

        couch_db:close(Db),
        if Limit > NewLimit, ResponseType == "longpoll" ->
            end_sending_changes(Callback, UserAcc2, EndSeq, ResponseType);
        true ->
            case wait_db_updated(Timeout, TimeoutFun, UserAcc2) of
            {updated, UserAcc4} ->
                DbOptions1 = [{user_ctx, Db#db.user_ctx} | DbOptions],
                case couch_db:open(Db#db.name, DbOptions1) of
                {ok, Db2} ->
                    keep_sending_changes(
                      Args#changes_args{limit=NewLimit},
                      ChangesAcc#changes_acc{
                        db = Db2,
                        user_acc = UserAcc4,
                        seq = EndSeq,
                        prepend = Prepend2,
                        timeout = Timeout,
                        timeout_fun = TimeoutFun},
                      false);
                _Else ->
                    end_sending_changes(Callback, UserAcc2, EndSeq,
                        ResponseType)
                end;
            {stop, UserAcc4} ->
                end_sending_changes(Callback, UserAcc4, EndSeq, ResponseType)
            end
        end;
    Error ->
        ?LOG_ERROR("Error while getting new changes: ~p~n", [Error]),
        #changes_acc{
            callback = Callback, seq = EndSeq,  user_acc = UserAcc2
        } = Acc0,
        end_sending_changes(Callback, UserAcc2, EndSeq, ResponseType)
    end.

end_sending_changes(Callback, UserAcc, EndSeq, ResponseType) ->
    Callback({stop, EndSeq}, ResponseType, UserAcc).

changes_enumerator(DocInfo, #changes_acc{resp_type = ResponseType} = Acc)
        when ResponseType =:= "continuous"
        orelse ResponseType =:= "eventsource" ->
    #changes_acc{
        filter = FilterFun, callback = Callback,
        user_acc = UserAcc, limit = Limit, db = Db,
        timeout = Timeout, timeout_fun = TimeoutFun
    } = Acc,
    #doc_info{high_seq = Seq} = DocInfo,
    Results0 = FilterFun(Db, DocInfo),
    Results = [Result || Result <- Results0, Result /= null],
    %% TODO: I'm thinking this should be < 1 and not =< 1
    Go = if Limit =< 1 -> stop; true -> ok end,
    case Results of
    [] ->
        {Done, UserAcc2} = maybe_heartbeat(Timeout, TimeoutFun, UserAcc),
        case Done of
        stop ->
            {stop, Acc#changes_acc{seq = Seq, user_acc = UserAcc2}};
        ok ->
            {Go, Acc#changes_acc{seq = Seq, user_acc = UserAcc2}}
        end;
    _ ->
        ChangesRow = changes_row(Results, DocInfo, Acc),
        UserAcc2 = Callback({change, ChangesRow, <<>>}, ResponseType, UserAcc),
        reset_heartbeat(),
        {Go, Acc#changes_acc{seq = Seq, user_acc = UserAcc2, limit = Limit - 1}}
    end;
changes_enumerator(DocInfo, Acc) ->
    #changes_acc{
        filter = FilterFun, callback = Callback, prepend = Prepend,
        user_acc = UserAcc, limit = Limit, resp_type = ResponseType, db = Db,
        timeout = Timeout, timeout_fun = TimeoutFun
    } = Acc,
    #doc_info{high_seq = Seq} = DocInfo,
    Results0 = FilterFun(Db, DocInfo),
    Results = [Result || Result <- Results0, Result /= null],
    Go = if (Limit =< 1) andalso Results =/= [] -> stop; true -> ok end,
    case Results of
    [] ->
        {Done, UserAcc2} = maybe_heartbeat(Timeout, TimeoutFun, UserAcc),
        case Done of
        stop ->
            {stop, Acc#changes_acc{seq = Seq, user_acc = UserAcc2}};
        ok ->
            {Go, Acc#changes_acc{seq = Seq, user_acc = UserAcc2}}
        end;
    _ ->
        ChangesRow = changes_row(Results, DocInfo, Acc),
        UserAcc2 = Callback({change, ChangesRow, Prepend}, ResponseType, UserAcc),
        reset_heartbeat(),
        {Go, Acc#changes_acc{
            seq = Seq, prepend = <<",\n">>,
            user_acc = UserAcc2, limit = Limit - 1}}
    end.

view_changes_enumerator({{_Key, _Seq}, {Id, _V}}, Acc) ->
    view_changes_enumerator1(Id, Acc).

view_changes_enumerator1(Id, Acc) ->
    #changes_acc{
        filter = FilterFun, callback = Callback, prepend = Prepend,
        user_acc = UserAcc, limit = Limit, resp_type = ResponseType, db = Db,
        timeout = Timeout, timeout_fun = TimeoutFun
    } = Acc,
    {ok, DocInfo} = couch_db:get_doc_info(Db, Id),
    #doc_info{high_seq = Seq} = DocInfo,
    Results0 = FilterFun(Db, DocInfo),
    Results = [Result || Result <- Results0, Result /= null],
    Go = if (Limit =< 1) andalso Results =/= [] -> stop; true -> ok end,
    case Results of
    [] ->
        {Done, UserAcc2} = maybe_heartbeat(Timeout, TimeoutFun, UserAcc),
        case Done of
        stop ->
            {stop, Acc#changes_acc{seq = Seq, user_acc = UserAcc2}};
        ok ->
            {Go, Acc#changes_acc{seq = Seq, user_acc = UserAcc2}}
        end;
    _ ->
        ChangesRow = changes_row(Results, DocInfo, Acc),
        UserAcc2 = Callback({change, ChangesRow, Prepend}, ResponseType, UserAcc),
        reset_heartbeat(),
        {Go, Acc#changes_acc{
            seq = Seq, prepend = <<",\n">>,
            user_acc = UserAcc2, limit = Limit - 1}}
    end.

changes_row(Results, DocInfo, Acc) ->
    #doc_info{
        id = Id, high_seq = Seq, revs = [#rev_info{deleted = Del} | _]
    } = DocInfo,
    #changes_acc{db = Db, include_docs = IncDoc, fields=Fields,
                 conflicts = Conflicts} = Acc,
    {[{<<"seq">>, Seq}, {<<"id">>, Id}, {<<"changes">>, Results}] ++
        deleted_item(Del) ++ case IncDoc of
            true ->
                Opts = case Conflicts of
                    true -> [deleted, conflicts];
                    false -> [deleted]
                end,
                Doc = couch_index_util:load_doc(Db, DocInfo, Opts),
                case Doc of
                    null -> [{doc, null}];
                    _ ->
                        case Fields of
                            [] ->

                                [{doc, couch_doc:to_json_obj(Doc, [])}];
                            _ ->
                                JsonObj = couch_doc:to_json_obj(Doc, []),
                                [{doc, filter_doc_fields(Fields,
                                                         JsonObj, [])}]
                        end
                end;
            false ->
                []
        end}.

deleted_item(true) -> [{<<"deleted">>, true}];
deleted_item(_) -> [].

% waits for a db_updated msg, if there are multiple msgs, collects them.
wait_db_updated(Timeout, TimeoutFun, UserAcc) ->
    receive
    db_updated ->
        get_rest_db_updated(UserAcc);
    {index_update, _} ->
        get_rest_db_updated(UserAcc);
    {index_shutdown, _} ->
         {stop, UserAcc}
    after Timeout ->
        {Go, UserAcc2} = TimeoutFun(UserAcc),
        case Go of
        ok ->
            wait_db_updated(Timeout, TimeoutFun, UserAcc2);
        stop ->
            {stop, UserAcc2}
        end
    end.

get_rest_db_updated(UserAcc) ->
    receive
    db_updated ->
        get_rest_db_updated(UserAcc);
    {index_update, _} ->
        get_rest_db_updated(UserAcc)
    after 0 ->
        {updated, UserAcc}
    end.

reset_heartbeat() ->
    case get(last_changes_heartbeat) of
    undefined ->
        ok;
    _ ->
        put(last_changes_heartbeat, now())
    end.

maybe_heartbeat(Timeout, TimeoutFun, Acc) ->
    Before = get(last_changes_heartbeat),
    case Before of
    undefined ->
        {ok, Acc};
    _ ->
        Now = now(),
        case timer:now_diff(Now, Before) div 1000 >= Timeout of
        true ->
            Acc2 = TimeoutFun(Acc),
            put(last_changes_heartbeat, Now),
            Acc2;
        false ->
            {ok, Acc}
        end
    end.


filter_docs(Req, Db, DDoc, FName, Docs) ->
    JsonReq = case Req of
    {json_req, JsonObj} ->
        JsonObj;
    #httpd{} = HttpReq ->
        couch_httpd_external:json_req_obj(HttpReq, Db)
    end,
    JsonDocs = [couch_doc:to_json_obj(Doc, [revs]) || Doc <- Docs],
    [true, Passes] = couch_query_servers:ddoc_prompt(DDoc, [<<"filters">>, FName],
        [JsonDocs, JsonReq]),
    {ok, Passes}.

filter_doc_fields([], {Props}, Acc) ->
    Id = proplists:get_value(<<"_id">>, Props),
    Rev = proplists:get_value(<<"_rev">>, Props),
    Acc1 = [{<<"_id">>, Id}, {<<"_rev">>, Rev}] ++ lists:reverse(Acc),
    {Acc1};
filter_doc_fields([Field|Rest], {Props}=Doc, Acc) ->
    Acc1 = case couch_util:get_value(Field, Props) of
        undefined ->
            Acc;
        Value ->
            [{Field, Value} | Acc]
    end,
    filter_doc_fields(Rest, Doc, Acc1).

parse_view_args({json_req, {Props}}) ->
    {Query} = couch_util:get_value(<<"query">>, Props, {[]}),
    parse_view_args1(Query, #mrargs{});
parse_view_args(Req) ->
    couch_mrview_http:parse_qs(Req, []).


parse_view_args1([], Args) ->
    Args;
parse_view_args1([{Key, Val} | Rest], Args) ->
    Args1 = case Key of
        <<"reduce">> ->
            Args#mrargs{reduce=Val};
        <<"key">> ->
            Args#mrargs{start_key=Val, end_key=Val};
        <<"keys">> ->
            Args#mrargs{keys=Val};
        <<"startkey">> ->
            Args#mrargs{start_key=Val};
        <<"start_key">> ->
            Args#mrargs{start_key=Val};
        <<"startkey_docid">> ->
            Args#mrargs{start_key_docid=Val};
        <<"start_key_doc_id">> ->
            Args#mrargs{start_key_docid=Val};
        <<"endkey">> ->
            Args#mrargs{end_key=Val};
        <<"end_key">> ->
            Args#mrargs{end_key=Val};
        <<"endkey_docid">> ->
            Args#mrargs{end_key_docid=Val};
        <<"end_key_doc_id">> ->
            Args#mrargs{end_key_docid=Val};
        <<"limit">> ->
            Args#mrargs{limit=Val};
        <<"count">> ->
            throw({query_parse_error, <<"QS param `count` is not `limit`">>});
        <<"stale">> when Val == <<"ok">> ->
            Args#mrargs{stale=ok};
        <<"stale">> when Val == <<"update_after">> ->
            Args#mrargs{stale=update_after};
        <<"stale">> ->
            throw({query_parse_error, <<"Invalid value for `stale`.">>});
        <<"descending">> ->
            case Val of
                true -> Args#mrargs{direction=rev};
                _ -> Args#mrargs{direction=fwd}
            end;
        <<"skip">> ->
            Args#mrargs{skip=Val};
        <<"group">> ->
            case Val of
                true -> Args#mrargs{group_level=exact};
                _ -> Args#mrargs{group_level=0}
            end;
        <<"group_level">> ->
            Args#mrargs{group_level=Val};
        <<"inclusive_end">> ->
            Args#mrargs{inclusive_end=Val};
        <<"include_docs">> ->
            Args#mrargs{include_docs=Val};
        <<"update_seq">> ->
            Args#mrargs{update_seq=Val};
        <<"conflicts">> ->
            Args#mrargs{conflicts=Val};
        <<"list">> ->
            Args#mrargs{list=Val};
        <<"callback">> ->
            Args#mrargs{callback=Val};
        _ ->
            Args#mrargs{extra=[{Key, Val} | Args#mrargs.extra]}
    end,
    parse_view_args1(Rest, Args1).
