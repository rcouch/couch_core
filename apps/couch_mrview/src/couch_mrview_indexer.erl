%%% -*- erlang -*-
%%%
%%% This file is part of couch_mrview released under the Apache 2 license.
%%% See the NOTICE for more information.

-module(couch_mrview_indexer).

-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-include_lib("couch/include/couch_db.hrl").

-record(state, {db_name, ddoc, notifier_pid}).

start_link(DbName, DDoc) ->
    gen_server:start_link(?MODULE, [DbName, DDoc] , []).

init([DbName, DDoc]) ->
    couch_util:with_db(DbName, fun(Db) ->
                couch_db:monitor(Db)
        end),
    {ok, Pid} = start_db_notifier(DbName, DDoc),
    {ok, #state{db_name=DbName, ddoc=DDoc, notifier_pid=Pid}}.


handle_call(_Msg, _From, State) ->
    {noreply, State}.


handle_cast(ddoc_updated, #state{db_name=DbName, ddoc=DDoc}=State) ->
    Shutdown = couch_util:with_db(DbName, fun(Db) ->
                    case couch_db:open_doc(Db, DDoc, [ejson_body]) of
                        {ok, _Doc} ->
                            false;
                        _ ->
                            true
                    end
            end),
    case Shutdown of
        true ->
            couch_mrview_events:notify(DbName, DDoc, index_shutdown),
            {stop, normal, State};
        _ ->
            spawn(fun() -> couch_mrview:refresh(DbName, DDoc) end),
            {noreply, State}
    end;
handle_cast(refresh, #state{db_name=DbName, ddoc=DDoc}=State) ->
    couch_mrview:refresh(DbName, DDoc),
    {noreply, State}.


handle_info({'DOWN', _, _, _Pid, _},
            #state{db_name=DbName, ddoc=DDoc}=State) ->

    ?LOG_INFO("Index shutdown by monitor notice for db: ~s idx: ~s",
              [DbName, DDoc]),

    couch_mrview_events:notify(DbName, DDoc, index_shutdown),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{notifier_pid=Pid}) ->
    catch couch_db_update_notifier:stop(Pid),
    ok.


start_db_notifier(DbName, DDoc) ->
    Self = self(),
    couch_db_update_notifier:start_link(fun
            ({ddoc_updated, {DbName1, DDoc1}})
                    when DbName1 =:= DbName, DDoc1 =:= DDoc->
                gen_server:cast(Self, ddoc_updated);
            ({updated, DbName1}) when DbName1 =:= DbName ->
                gen_server:cast(Self, refresh);
            (_) ->
                ok
        end).

