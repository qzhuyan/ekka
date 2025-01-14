%%--------------------------------------------------------------------
%% Copyright (c) 2019-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(ekka_mnesia).

-include("ekka.hrl").
-include("ekka_rlog.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("snabbkaffe/include/trace.hrl").


%% Start and stop mnesia
-export([ start/0
        , ensure_started/0
        , ensure_stopped/0
        , connect/1
        ]).

%% Mnesia Cluster API
-export([ join_cluster/1
        , leave_cluster/0
        , remove_from_cluster/1
        , cluster_info/0
        , cluster_status/1
        , cluster_view/0
        , cluster_nodes/1
        , running_nodes/0
        ]).

-export([ is_node_in_cluster/0
        , is_node_in_cluster/1
        ]).

%% Dir, schema and tables
-export([ data_dir/0
        , copy_schema/1
        , delete_schema/0
        , del_schema_copy/1
        , create_table/2
        , create_table_internal/2
        , copy_table/1
        , copy_table/2
        , wait_for_tables/1
        ]).

%% Database API
-export([ ro_transaction/2
        , transaction/3
        , transaction/2
        , clear_table/1

        , dirty_write/2
        , dirty_write/1

        , dirty_delete/2
        , dirty_delete/1

        , dirty_delete_object/2

        , local_content_shard/0
        ]).

-export_type([ t_result/1
             , backend/0
             , table/0
             , table_config/0
             ]).

-deprecated({copy_table, 1, next_major_release}).

-type t_result(Res) :: {'atomic', Res} | {'aborted', Reason::term()}.

-type backend() :: rlog | mnesia.

-type table() :: atom().

-type table_config() :: list().

%%--------------------------------------------------------------------
%% Start and init mnesia
%%--------------------------------------------------------------------

%% @doc Start mnesia database
-spec(start() -> ok | {error, term()}).
start() ->
    ensure_ok(ensure_data_dir()),
    ensure_ok(init_schema()),
    ok = mnesia:start(),
    {ok, _} = ekka_mnesia_null_storage:register(),
    ok = ekka_rlog:init(),
    init_tables(),
    wait_for(tables).

%% @private
ensure_data_dir() ->
    case filelib:ensure_dir(data_dir()) of
        ok              -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% @doc Data dir
-spec(data_dir() -> string()).
data_dir() -> mnesia:system_info(directory).

%% @doc Ensure mnesia started
-spec(ensure_started() -> ok | {error, any()}).
ensure_started() ->
    ok = mnesia:start(),
    {ok, _} = ekka_mnesia_null_storage:register(),
    wait_for(start).

%% @doc Ensure mnesia stopped
-spec(ensure_stopped() -> ok | {error, any()}).
ensure_stopped() ->
    stopped = mnesia:stop(), wait_for(stop).

%% @private
%% @doc Init mnesia schema or tables.
init_schema() ->
    IsAlone = case mnesia:system_info(extra_db_nodes) of
                  []    -> true;
                  [_|_] -> false
              end,
    case (ekka_rlog:role() =:= replicant) orelse IsAlone of
        true ->
            mnesia:create_schema([node()]);
        false ->
            ok
    end.

%% @private
%% @doc Init mnesia tables.
init_tables() ->
    IsAlone = case mnesia:system_info(extra_db_nodes) of
                  []    -> true;
                  [_|_] -> false
              end,
    case (ekka_rlog:role() =:= replicant) orelse IsAlone of
        true ->
            ekka_rlog_schema:init(boot),
            create_tables();
        false ->
            ekka_rlog_schema:init(copy),
            copy_tables()
    end.

%% @doc Create mnesia tables.
create_tables() ->
    ekka_boot:apply_module_attributes(boot_mnesia).

%% @doc Copy mnesia tables.
copy_tables() ->
    ekka_boot:apply_module_attributes(copy_mnesia).

%% @doc Create mnesia table.
-spec(create_table(Name:: table(), TabDef :: list()) -> ok | {error, any()}).
create_table(Name, TabDef) ->
    ?tp(debug, ekka_mnesia_create_table,
        #{ name    => Name
         , options => TabDef
         }),
    MnesiaTabDef = lists:keydelete(rlog_shard, 1, TabDef),
    case {proplists:get_value(rlog_shard, TabDef, ?LOCAL_CONTENT_SHARD),
          proplists:get_value(local_content, TabDef, false)} of
        {?LOCAL_CONTENT_SHARD, true} ->
            %% Local content table:
            create_table_internal(Name, MnesiaTabDef);
        {?LOCAL_CONTENT_SHARD, false} ->
            ?LOG(critical, "Table ~p doesn't belong to any shard", [Name]),
            error(badarg);
        {Shard, false} ->
            case create_table_internal(Name, MnesiaTabDef) of
                ok ->
                    %% It's important to add the table to the shard
                    %% _after_ we actually create it:
                    ekka_rlog_schema:add_table(Shard, Name, MnesiaTabDef);
                Err ->
                    Err
            end;
        {_Shard, true} ->
            ?LOG(critical, "local_content table ~p should belong to ?LOCAL_CONTENT_SHARD.", [Name]),
            error(badarg)
    end.

%% @doc Create mnesia table (skip RLOG stuff)
-spec(create_table_internal(Name:: atom(), TabDef :: list()) -> ok | {error, any()}).
create_table_internal(Name, TabDef) ->
    ensure_tab(mnesia:create_table(Name, TabDef)).

%% @doc Copy mnesia table.
-spec(copy_table(Name :: atom()) -> ok).
copy_table(Name) ->
    copy_table(Name, ram_copies).

-spec(copy_table(Name:: atom(), ram_copies | disc_copies | null_copies) -> ok).
copy_table(Name, RamOrDisc) ->
    case ekka_rlog:role() of
        core ->
            ensure_tab(mnesia:add_table_copy(Name, node(), RamOrDisc));
        replicant ->
            ?LOG(warning, "Ignoring illegal attempt to create a table copy ~p on replicant node ~p", [Name, node()])
    end.

%% @doc Copy schema.
copy_schema(Node) ->
    case mnesia:change_table_copy_type(schema, Node, disc_copies) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, schema, Node, disc_copies}} ->
            ok;
        {aborted, Error} ->
            {error, Error}
    end.

%% @doc Force to delete schema.
delete_schema() ->
    mnesia:delete_schema([node()]).

%% @doc Delete schema copy
del_schema_copy(Node) ->
    case mnesia:del_table_copy(schema, Node) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Cluster mnesia
%%--------------------------------------------------------------------

%% @doc Join the mnesia cluster
-spec(join_cluster(node()) -> ok).
join_cluster(Node) when Node =/= node() ->
    case {ekka_rlog:role(), ekka_rlog:role(Node)} of
        {core, core} ->
            %% Stop mnesia and delete schema first
            ensure_ok(ensure_stopped()),
            ensure_ok(delete_schema()),
            %% Start mnesia and cluster to node
            ensure_ok(ensure_started()),
            ensure_ok(connect(Node)),
            ensure_ok(copy_schema(node())),
            %% Copy tables
            copy_tables(),
            ensure_ok(wait_for(tables));
        _ ->
            ok
    end.

%% @doc Cluster Info
-spec(cluster_info() -> map()).
cluster_info() ->
    Running = cluster_nodes(running),
    Stopped = cluster_nodes(stopped),
    #{running_nodes => lists:sort(Running),
      stopped_nodes => lists:sort(Stopped)
     }.

%% @doc Cluster status of the node
-spec(cluster_status(node()) -> running | stopped | false).
cluster_status(Node) ->
    case is_node_in_cluster(Node) of
        true ->
            case lists:member(Node, running_nodes()) of
                true  -> running;
                false -> stopped
            end;
        false -> false
    end.

-spec(cluster_view() -> {[node()], [node()]}).
cluster_view() ->
    list_to_tuple([lists:sort(cluster_nodes(Status))
                   || Status <- [running, stopped]]).

%% @doc This node try leave the cluster
-spec(leave_cluster() -> ok | {error, any()}).
leave_cluster() ->
    case running_nodes() -- [node()] of
        [] ->
            {error, node_not_in_cluster};
        Nodes ->
            case lists:any(fun(Node) ->
                            case leave_cluster(Node) of
                                ok               -> true;
                                {error, _Reason} -> false
                            end
                          end, Nodes) of
                true  -> ok;
                false -> {error, {failed_to_leave, Nodes}}
            end
    end.

-spec(leave_cluster(node()) -> ok | {error, any()}).
leave_cluster(Node) when Node =/= node() ->
    case is_running_db_node(Node) of
        true ->
            ensure_ok(ensure_stopped()),
            ensure_ok(rpc:call(Node, ?MODULE, del_schema_copy, [node()])),
            ensure_ok(delete_schema());
            %%ensure_ok(start()); %% restart?
        false ->
            {error, {node_not_running, Node}}
    end.

%% @doc Remove node from mnesia cluster.
-spec(remove_from_cluster(node()) -> ok | {error, any()}).
remove_from_cluster(Node) when Node =/= node() ->
    case {is_node_in_cluster(Node), is_running_db_node(Node)} of
        {true, true} ->
            ensure_ok(rpc:call(Node, ?MODULE, ensure_stopped, [])),
            mnesia_lib:del(extra_db_nodes, Node),
            ensure_ok(del_schema_copy(Node)),
            ensure_ok(rpc:call(Node, ?MODULE, delete_schema, []));
        {true, false} ->
            mnesia_lib:del(extra_db_nodes, Node),
            ensure_ok(del_schema_copy(Node));
            %ensure_ok(rpc:call(Node, ?MODULE, delete_schema, []));
        {false, _} ->
            {error, node_not_in_cluster}
    end.

%% @doc Is this node in mnesia cluster?
is_node_in_cluster() ->
    ekka_mnesia:cluster_nodes(all) =/= [node()].

%% @doc Is the node in mnesia cluster?
-spec(is_node_in_cluster(node()) -> boolean()).
is_node_in_cluster(Node) when Node =:= node() ->
    is_node_in_cluster();
is_node_in_cluster(Node) ->
    lists:member(Node, cluster_nodes(all)).

%% @private
%% @doc Is running db node.
is_running_db_node(Node) ->
    lists:member(Node, running_nodes()).

%% @doc Cluster with node.
-spec(connect(node()) -> ok | {error, any()}).
connect(Node) ->
    case mnesia:change_config(extra_db_nodes, [Node]) of
        {ok, [Node]} -> ok;
        {ok, []}     -> {error, {failed_to_connect_node, Node}};
        Error        -> Error
    end.

%% @doc Running nodes.
-spec(running_nodes() -> list(node())).
running_nodes() ->
    case ekka_rlog:role() of
        core ->
            CoreNodes = mnesia:system_info(running_db_nodes),
            {Replicants0, _} = rpc:multicall(CoreNodes, ekka_rlog_status, replicants, []),
            Replicants = [Node || Nodes <- Replicants0, is_list(Nodes), Node <- Nodes],
            lists:usort(CoreNodes ++ Replicants);
        replicant ->
            case ekka_rlog_status:shards_up() of
                [Shard|_] ->
                    {ok, CoreNode} = ekka_rlog_status:upstream_node(Shard),
                    case ekka_rlog_lib:rpc_call(CoreNode, ?MODULE, running_nodes, []) of
                        {badrpc, _} -> [];
                        {badtcp, _} -> [];
                        Result      -> Result
                    end;
                [] ->
                    []
            end
    end.

%% @doc Cluster nodes.
-spec(cluster_nodes(all | running | stopped) -> [node()]).
cluster_nodes(all) ->
    Running = running_nodes(),
    %% Note: stopped replicant nodes won't appear in the list
    lists:usort(Running ++ mnesia:system_info(db_nodes));
cluster_nodes(running) ->
    running_nodes();
cluster_nodes(stopped) ->
    cluster_nodes(all) -- cluster_nodes(running).

%% @private
ensure_ok(ok) -> ok;
ensure_ok({error, {Node, {already_exists, Node}}}) -> ok;
ensure_ok({badrpc, Reason}) -> throw({error, {badrpc, Reason}});
ensure_ok({error, Reason}) -> throw({error, Reason}).

%% @private
ensure_tab({atomic, ok})                             -> ok;
ensure_tab({aborted, {already_exists, _Name}})       -> ok;
ensure_tab({aborted, {already_exists, _Name, _Node}})-> ok;
ensure_tab({aborted, Error})                         -> Error.

%% @doc Wait for mnesia to start, stop or tables ready.
-spec(wait_for(start | stop | tables) -> ok | {error, Reason :: term()}).
wait_for(start) ->
    case mnesia:system_info(is_running) of
        yes      -> ok;
        no       -> {error, mnesia_unexpectedly_stopped};
        stopping -> {error, mnesia_unexpectedly_stopping};
        starting -> timer:sleep(1000), wait_for(start)
    end;
wait_for(stop) ->
    case mnesia:system_info(is_running) of
        no       -> ok;
        yes      -> {error, mnesia_unexpectedly_running};
        starting -> {error, mnesia_unexpectedly_starting};
        stopping -> timer:sleep(1000), wait_for(stop)
    end;
wait_for(tables) ->
    Tables = mnesia:system_info(local_tables),
    wait_for_tables(Tables).

wait_for_tables(Tables) ->
    case mnesia:wait_for_tables(Tables, 30000) of
        ok                   -> ok;
        {error, Reason}      -> {error, Reason};
        {timeout, BadTables} ->
            logger:warning("~p: still waiting for table(s): ~p", [?MODULE, BadTables]),
            %% lets try to force reconnect all the db_nodes to get schema merged,
            %% mnesia_controller is smart enough to not force reconnect the node that is already connected.
            mnesia_controller:connect_nodes(mnesia:system_info(db_nodes)),
            wait_for_tables(BadTables)
    end.

local_content_shard() ->
    ?LOCAL_CONTENT_SHARD.

%%--------------------------------------------------------------------
%% Transaction API
%%--------------------------------------------------------------------

-spec ro_transaction(ekka_rlog:shard(), fun(() -> A)) -> t_result(A).
ro_transaction(?LOCAL_CONTENT_SHARD, Fun) ->
    mnesia:transaction(fun ekka_rlog_activity:ro_transaction/1, [Fun]);
ro_transaction(Shard, Fun) ->
    case ekka_rlog:role() of
        core ->
            mnesia:transaction(fun ekka_rlog_activity:ro_transaction/1, [Fun]);
        replicant ->
            ?tp(ekka_ro_transaction, #{role => replicant}),
            case ekka_rlog_status:upstream(Shard) of
                {ok, AgentPid} ->
                    Ret = mnesia:transaction(fun ekka_rlog_activity:ro_transaction/1, [Fun]),
                    %% Now we check that the agent pid is still the
                    %% same, meaning the replicant node haven't gone
                    %% through bootstrapping process while running the
                    %% transaction and it didn't have a chance to
                    %% observe the stale writes.
                    case ekka_rlog_status:upstream(Shard) of
                        {ok, AgentPid} ->
                            Ret;
                        _ ->
                            %% Restart transaction. If the shard is
                            %% still disconnected, it will become an
                            %% RPC call to a core node:
                            ro_transaction(Shard, Fun)
                    end;
                disconnected ->
                    ro_trans_rpc(Shard, Fun)
            end
    end.

-spec transaction(ekka_rlog:shard(), fun((...) -> A), list()) -> t_result(A).
transaction(Shard, Fun, Args) ->
    ekka_rlog_lib:call_backend_rw_trans(Shard, transaction, [Fun, Args]).

-spec transaction(ekka_rlog:shard(), fun(() -> A)) -> t_result(A).
transaction(Shard, Fun) ->
    transaction(Shard, fun erlang:apply/2, [Fun, []]).

-spec clear_table(ekka_mnesia:table()) -> t_result(ok).
clear_table(Table) ->
    Shard = ekka_rlog_config:shard_rlookup(Table),
    ekka_rlog_lib:call_backend_rw_trans(Shard, clear_table, [Table]).

-spec dirty_write(tuple()) -> ok.
dirty_write(Record) ->
    dirty_write(element(1, Record), Record).

-spec dirty_write(ekka_mnesia:table(), tuple()) -> ok.
dirty_write(Tab, Record) ->
    ekka_rlog_lib:call_backend_rw_dirty(dirty_write, Tab, [Record]).

-spec dirty_delete(ekka_mnesia:table(), term()) -> ok.
dirty_delete(Tab, Key) ->
    ekka_rlog_lib:call_backend_rw_dirty(dirty_delete, Tab, [Key]).

-spec dirty_delete({ekka_mnesia:table(), term()}) -> ok.
dirty_delete({Tab, Key}) ->
    dirty_delete(Tab, Key).

-spec dirty_delete_object(ekka_mnesia:table(), term()) -> ok.
dirty_delete_object(Tab, Key) ->
    ekka_rlog_lib:call_backend_rw_dirty(dirty_delete_object, Tab, [Key]).

%%================================================================================
%% Internal functions
%%================================================================================

-spec ro_trans_rpc(ekka_rlog:shard(), fun(() -> A)) -> t_result(A).
ro_trans_rpc(Shard, Fun) ->
    {ok, Core} = ekka_rlog_status:get_core_node(Shard, 5000),
    case ekka_rlog_lib:rpc_call(Core, ?MODULE, ro_transaction, [Shard, Fun]) of
        {badrpc, Err} ->
            ?tp(error, ro_trans_badrpc,
                #{ core   => Core
                 , reason => Err
                 }),
            error(badrpc);
        {badtcp, Err} ->
            ?tp(error, ro_trans_badtcp,
                #{ core   => Core
                 , reason => Err
                 }),
            error(badrpc);
        Ans ->
            Ans
    end.
