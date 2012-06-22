%%% -*- erlang -*-
%%%
%%% This file is part of couch_mrview released under the Apache 2 license.
%%% See the NOTICE for more information.

-module(couch_mrview_events).
-behaviour(gen_server).

-export([start_link/0,
         subscribe/2, unsubscribe/2,
         notify/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).


-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").


-define(SUBS, couch_mrview_events_subs).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

subscribe(DbName, DDoc) ->
    Self = self(),
    gen_server:call(?MODULE, {subscribe, DbName, DDoc, Self}).

unsubscribe(DbName, DDoc) ->
    Self = self(),
    gen_server:call(?MODULE, {unsubscribe, DbName, DDoc, Self}).

notify(DbName, DDoc, Event) ->
    gen_server:cast(?MODULE, {notify, DbName, DDoc, Event}).


init(_) ->
    ets:new(?SUBS, [bag, named_table, public]),
    Indexers = dict:new(),
    {ok, Indexers}.


handle_call({subscribe, DbName, DDoc, Subscriber}, _From, Indexers) ->
    Key = {DbName, DDoc},
    Indexers2 = case dict:find(Key, Indexers) of
        {ok, _Pid} ->
            true = ets:insert(?SUBS, {Key, Subscriber});
        error ->
            {ok, Pid} = couch_mrview_indexer_sup:start_indexer(DbName, DDoc),
            Indexers1 = dict:store(Key, Pid, Indexers),
            true = ets:insert(?SUBS, {Key, Subscriber}),
            Indexers1
    end,
    {reply, ok, Indexers2};

handle_call({unsubscribe, DbName, DDoc, Subscriber}, _From, Indexers) ->
    Key = {DbName, DDoc},
    Indexers2 = case ets:member(?SUBS, Key) of
        true ->
            ets:delete_object(?SUBS, {Key, Subscriber}),
            maybe_stop_indexer(Key, Indexers);
        _ ->
            Indexers
    end,

    {reply, ok, Indexers2}.


handle_cast({notify, DbName, DDoc, Event}, Indexers) ->
    case ets:lookup(?SUBS, {DbName, DDoc}) of
        [] ->
            ok;
        Subs ->
            lists:foreach(fun({Key, Pid}=Sub) ->
                        case is_process_alive(Pid) of
                            true ->
                                Pid ! {Event, Key};
                            false ->
                                ets:delete_object(?SUBS, Sub)
                        end
                end, Subs)
    end,

    Indexers2 = maybe_stop_indexer({DbName, DDoc}, Indexers),
    {noreply, Indexers2}.

handle_info(_Info, Indexers) ->
    {noreply, Indexers}.


code_change(_OldVsn, Indexers, _Extra) ->
    {ok, Indexers}.

terminate(_Reason, Indexers) ->
    try
        %% kill all indexers
        dict:fold(fun(_Key, Pid, _Acc) ->
                    supervisor:terminate_child(couch_mrview_indexer_sup, Pid),
                    nil
            end, nil, Indexers)
    catch
        _:_ -> ok
    end,
    ok.

maybe_stop_indexer(Key, Indexers) ->
    case ets:lookup(?SUBS, Key) of
        [] ->
            case dict:find(Key, Indexers) of
                {ok, Pid} ->
                    supervisor:terminate_child(couch_mrview_indexer_sup,
                                               Pid),
                    dict:erase(Key, Indexers);
                _ ->
                    Indexers
            end;
        _ ->
            Indexers
    end.




