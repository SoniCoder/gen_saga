-module(gen_saga_pool_sup).

-behaviour(supervisor3).

%% Supervisor callbacks
-export([init/1, post_init/1]).

-include("src/butler_server.hrl").

%% API
-export([
         start_link/0,
         start_child/1,
         stop_child/1,
         stop_children/1
        ]).

-define(SERVER, ?MODULE).

%% @doc Starts the Supervisor.
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link() ->
    supervisor3:start_link({global, ?SERVER}, ?MODULE, []).

-spec start_child(term()) -> any().
start_child(WorkerId) ->
    StartResult = supervisor3:start_child({global, ?SERVER}, [WorkerId]),
    case StartResult of
        {ok, _} -> StartResult;
        {error,{shutdown,{failed_to_start_child,_,{already_started,_}}}} ->
            StartResult,
            {ok, something_already_started};
        _ ->
            ?ERROR("Failure while starting child: ~p", [StartResult]),
            {error, start_failure}
    end.

-spec stop_child(term()) -> any().
stop_child(WorkerId) ->
    case global:whereis_name({gen_saga_pool_worker, WorkerId}) of
        undefined ->
            ok;
        Pid ->
            supervisor3:terminate_child({global, ?SERVER}, Pid)
    end.

-spec stop_children(list()) -> ok.
stop_children(WorkerIdList) ->
    lists:foreach(
      fun(WorkerId) ->
        pps_factory:stop_child(WorkerId)
      end,
      WorkerIdList
     ).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

%% @private
%% @doc Tells about restart strategy, max restart freq, and child specs.
-spec init (any()) -> {ok, {{supervisor3:strategy(),
                             non_neg_integer(),
                             pos_integer()},
                            [supervisor3:child_spec()]}} | ignore.
init([]) ->
    ?INFO("Starting ~p", [?MODULE]),
    GenSagaPoolWorker  = {gen_saga_pool_worker, {gen_saga_pool_worker, start_link, []},
                {permanent, 30}, 5000, worker, [gen_saga_pool_worker]},
    Children = [GenSagaPoolWorker],
    RestartStrategy = {simple_one_for_one, 2, 30},
    {ok, {RestartStrategy, Children}}.


post_init([]) -> ignore.
