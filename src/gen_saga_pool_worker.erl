-module(gen_saga_pool_worker).
-behaviour(gen_statem).

-include_lib("gen_saga/src/gen_saga.hrl").

%% API
-export([
         start_link/1,
         set_processing_enabled/1,
         set_processing_disabled/1
        ]).

%% gen_statem callbacks
-export([init/1, handle_event/4, callback_mode/0,
            terminate/3]).

-define(SERVER, ?MODULE).

-record(state, {
    app_name = undefined,
    partition = undefined,
    processing_enabled = true,
    saga_list = []
}).

%% @doc Starts the Supervisor.
-spec start_link(term()) -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link({AppName, Partition}) ->
    gen_statem:start_link({global, {?SERVER, {AppName, Partition}}}, ?MODULE, [AppName, Partition], []).

set_processing_enabled(WorkerId) ->
    gen_statem:call({global, {?SERVER, WorkerId}}, {set_processing_enabled}).

set_processing_disabled(WorkerId) ->
    gen_statem:call({global, {?SERVER, WorkerId}}, {set_processing_disabled}).

callback_mode() ->
    handle_event_function.

init([AppName, Partition]) ->
    lager:info("Starting Saga Pool Worker App: ~p Partition: ~p", [AppName, Partition]),
    InitState =
        #state{
            app_name = AppName,
            partition = Partition
        },
    {ok, ready, InitState, [{next_event, cast, {process_saga}}]}.

handle_event(_EventType, {process_saga}, ready, #state{processing_enabled = ProcessingEnabled} = StateData) when
                            ProcessingEnabled =:= false ->

    lager:debug("Ignoring Saga Processing since processing is disabled"),
    WorkerPollingInterval = application:get_env(gen_saga, worker_polling_interval, 1000),
    {keep_state, StateData,  [{state_timeout,
        WorkerPollingInterval, {process_saga}}]};

handle_event(EventType, {process_saga}, ready, #state{app_name = AppName, partition = Partition, saga_list = []} = StateData) when
                            EventType =:= state_timeout;
                            EventType =:= cast ->

    Sagas = mnesia:dirty_select(gen_saga_persist,
                [{#gen_saga_persist{
                    id = '$1', app = AppName, partition = Partition, execution_type = auto, _ = '_'
                }, [], ['$1']}]),
    case Sagas of
        [] ->
            WorkerPollingInterval = application:get_env(gen_saga, worker_polling_interval, 1000),
            {keep_state, StateData,  [{state_timeout,
                WorkerPollingInterval, {process_saga}}]};
        [SagaId | RemSagas] ->
            process_saga(SagaId),
            {keep_state, StateData#state{saga_list = RemSagas}, [{next_event, cast, {process_saga}}]}
    end;

handle_event(cast, {process_saga}, ready, #state{saga_list = [SagaId| RemSagaList]} = StateData) ->
    process_saga(SagaId),
    {keep_state, StateData#state{saga_list = RemSagaList}, [{next_event, cast, {process_saga}}]};

handle_event({call, From}, {set_processing_disabled}, _StateName, StateData) ->
    {keep_state, StateData#state{processing_enabled = false}, [{reply, From, ok}]};

handle_event({call, From}, {set_processing_enabled}, _StateName, StateData) ->
    {keep_state, StateData#state{processing_enabled = true}, [{reply, From, ok}]};

handle_event(EventType, Event, StateName, _StateData) ->
    lager:info("Unhandled event: ~p of type: ~p received in state: ~p", [Event, EventType, StateName]),
    keep_state_and_data.

process_saga(SagaId) ->
    try
        {atomic, _} = mnesia:transaction(
            fun() ->
                {ok, SelectedSaga} = gen_saga:get_by_id(SagaId),
                Partition = SelectedSaga#gen_saga_persist.partition,
                OldRetryCount = SelectedSaga#gen_saga_persist.retry_count,
                CountUpdatedSaga = SelectedSaga#gen_saga_persist{retry_count = OldRetryCount + 1},
                mnesia:dirty_write(CountUpdatedSaga),
                lager:debug("Processing Saga: Id: ~p Partition: ~p", [SagaId, Partition]),
                ControllerState = SelectedSaga#gen_saga_persist.controller_state,
                [M, F, A] = ControllerState#saga_controller_state.saga_state,
                apply(M, F, A),
                gen_saga:delete(SagaId)
            end
        )
    catch
        Class:Exception:Stacktrace ->
            lager:error("Exception Occurred while processing Saga - Id: ~p Exception: ~p Stacktrace: ~p",
                [SagaId, {Class, Exception}, Stacktrace]),
            erlang:throw({Class, Exception})
    end.

%% @private
%% @doc Opposite of init.
terminate(_Reason, _StateName, _State) ->
    ok.
