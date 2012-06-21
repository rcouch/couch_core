%%% -*- erlang -*-
%%%
%%% This file is part of couch_mrview released under the Apache 2 license.
%%% See the NOTICE for more information.

-module(couch_mrview_indexer_sup).
-behaviour(supervisor).

-export([start_indexer/2]).
-export([start_link/0, stop/1]).

-export([init/1]).

start_indexer(DbName, DDoc) ->
    supervisor:start_child(?MODULE, [DbName, DDoc]).



start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

stop(_S) -> ok.

%% @private
init([]) ->
    {ok,
     {{simple_one_for_one, 10, 10},
      [{couch_mrview_indexer,
        {couch_mrview_indexer, start_link, []},
        permanent, 5000, worker, [couch_mrview_indexer]}]}}.
