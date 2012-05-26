{application,couch_stats,
             [{description,"CouchDB stats"},
              {vsn,"0.1"},
              {modules,[couch_stats_aggregator,couch_stats_app,
                        couch_stats_collector,couch_stats_sup]},
              {registered,[couch_stats_aggregator,couch_stats_collector]},
              {applications,[kernel,stdlib]},
              {mod,{couch_stats_app,[]}}]}.
