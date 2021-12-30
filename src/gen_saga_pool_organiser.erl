-module(gen_saga_pool_organiser).
-behaviour(gen_statem).

-include("src/butler_server.hrl").

%% API
-export([
         start_link/0,
         get_all_worker_ids/0,
         enable_processing/0,
         disable_processing/0
        ]).

%% gen_statem callbacks
-export([init/1, handle_event/4, callback_mode/0,
            terminate/3]).

-define(SERVER, ?MODULE).

%% @doc Starts the Supervisor.
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link() ->
    gen_statem:start_link({global, ?SERVER}, ?MODULE, [], []).

get_all_worker_ids() ->
    DefaultPartitions = application:get_env(gen_saga, partitions, 100),
    DefaultWorkers =
        lists:map(
            fun(X) ->
                {undefined, X}
            end,
        lists:seq(0, DefaultPartitions - 1)),

    AppPools = application:get_env(gen_saga, app_pools, #{}),

    maps:fold(
        fun(App, AppSpec, WorkersAcc) ->
            Partitions = maps:get(partitions, AppSpec, DefaultPartitions),
            lists:foldl(
                fun(WorkerId, WorkersAcc1) ->
                    [{App, WorkerId} | WorkersAcc1]
                end,
                WorkersAcc,
            lists:seq(0, Partitions - 1))
        end,
    DefaultWorkers,
    AppPools).

disable_processing() ->
    lists:foreach(
        fun(WorkerId) ->
            gen_saga_pool_worker:set_processing_disabled(WorkerId)
        end,
    get_all_worker_ids()).

enable_processing() ->
    lists:foreach(
        fun(WorkerId) ->
            gen_saga_pool_worker:set_processing_enabled(WorkerId)
        end,
    get_all_worker_ids()).

callback_mode() ->
    handle_event_function.

init([]) ->
    Partitions = application:get_env(gen_saga, partitions, 100),
    Nodes = hash_ring:list_to_nodes(lists:seq(0, Partitions - 1)),
    Ring = hash_ring:make(Nodes),
    persistent_term:put(gen_saga_ring, Ring),

    ?INFO("Starting Saga Pool Organiser"),
    lists:foreach(
        fun(WorkerId) ->
            gen_saga_pool_sup:start_child(WorkerId)
        end,
    get_all_worker_ids()),

    {ok, ready, #{}}.

handle_event(EventType, Event, StateName, _StateData) ->
    ?INFO("Unhandled event: ~p of type: ~p received in state: ~p", [Event, EventType, StateName]),
    keep_state_and_data.

%% @private
%% @doc Opposite of init.
terminate(_Reason, _StateName, _State) ->
    ok.
