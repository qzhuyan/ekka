-ifndef(EKKA_RLOG_HRL).
-define(EKKA_RLOG_HRL, true).

-record(rlog,
        { key :: ekka_rlog_lib:txid()
        , ops :: ekka_rlog_lib:tx()
        }).

-define(schema, ekka_rlog_schema).

-record(?schema,
        { mnesia_table :: ekka_mnesia:table()
        , shard        :: ekka_rlog:shard()
        , config       :: ekka_mnesia:table_config() | '$2' | '_' %% TODO: fix type
        }).

-define(LOCAL_CONTENT_SHARD, undefined).

-endif.
