-module(gen_saga).

-include("src/butler_server.hrl").
-include("gen_saga.hrl").

-define(MODEL, gen_saga_persist).

-compile(export_all).

%% @doc retrieves the number of partitions defined for a particular app in config
%% takes the default number of partitions if nothing is defined in config
-spec get_partition_count_for_app(atom()) -> integer().
get_partition_count_for_app(AppName) ->
    DefaultPartitions = application:get_env(gen_saga, partitions, 100),
    AppPools = application:get_env(gen_saga, app_pools, #{}),
    case maps:get(AppName, AppPools, undefined) of
        undefined -> DefaultPartitions;
        AppSpec ->
            maps:get(partitions, AppSpec, DefaultPartitions)
    end.

%% @doc create a promise that will be executed by one of the saga pool workers
-spec promise(atom(), atom(), list()) -> ok.
promise(M, F, A) ->
    create_promise_internal(undefined, M, F, A).

promise(K, M, F, A) ->
    Ring = persistent_term:get(gen_saga_ring),
    {ok, SelectedNode} = hash_ring:find_node(K, Ring),
    SelectedPartition = hash_ring_node:get_key(SelectedNode),
    create_promise_internal(SelectedPartition, M, F, A).

create_promise_internal(P, M, F, A) ->
    Id = mnesia:dirty_update_counter('table_counters', gen_saga_persist, 1),
    AppName1 =
        case application:get_application() of
            {ok, AppName0} -> AppName0;
            _ -> undefined
        end,
    AppPools = application:get_env(gen_saga, app_pools, #{}),
    AppName =
        case maps:get(AppName1, AppPools, undefined) of
            undefined -> undefined;
            _ -> AppName1
        end,
    Partition =
        case P of
            undefined ->
                Partitions = get_partition_count_for_app(AppName),
                rand:uniform(Partitions) - 1;
            _ -> P
        end,
    SagaRecord =
        #gen_saga_persist{
            id = Id,
            partition = Partition,
            app = AppName,
            type = test,
            subtype = test,
            name = test,
            status = created,
            execution_type = auto,
            retry_count = 0,
            update_time = calendar:universal_time(),
            controller_state =
                #saga_controller_state{saga_state = [M, F, A]}
        },
    create_or_update(Id, SagaRecord, []),
    ok.

%% @doc initialize a manual saga and starts
%% processing immediately by the caller process
-spec init(atom(), term()) -> {ok, term()}.
init(SagaMod, Args) ->
    {ok, SagaState, SagaOpts} = SagaMod:init(Args),
    Type = maps:get(type, SagaOpts, undefined),
    SubType = maps:get(subtype, SagaOpts, undefined),
    TaskList = SagaMod:saga_tasks(),
    TaskMap =
        lists:foldl(
            fun(TaskName, TaskMapAcc) ->
                TaskMapAcc#{TaskName => #task_state{}}
            end,
            #{},
        TaskList),
    ControllerState = #saga_controller_state{
        saga_mod = SagaMod,
        saga_state = SagaState,
        taskmap = TaskMap
    },
    SagaId = mnesia:dirty_update_counter('table_counters', gen_saga_persist, 1),
    AppName1 =
        case application:get_application() of
            {ok, AppName0} -> AppName0;
            _ -> undefined
        end,
    AppPools = application:get_env(gen_saga, app_pools, #{}),
    AppName =
        case maps:get(AppName1, AppPools, undefined) of
            undefined -> undefined;
            _ -> AppName1
        end,
    Partitions = get_partition_count_for_app(AppName),
    Partition = rand:uniform(Partitions) - 1,
    SagaRec =
        #gen_saga_persist{
            id = SagaId,
            partition = Partition,
            app = AppName,
            type = Type,
            subtype = SubType,
            status = created,
            execution_type = manual,
            retry_count = 0,
            update_time = calendar:universal_time(),
            controller_state = ControllerState
        },
    baseinfo:create(?MODEL, SagaId, SagaRec, []),
    process_saga(SagaId),
    {ok, SagaId}.

%% @doc start saga processing
-spec process_saga(saga_id()) -> ok.
process_saga(SagaId) ->
    {ok, SagaRec} = gen_saga:get_by_id(SagaId),
    ControllerState = SagaRec#gen_saga_persist.controller_state,
    TaskMap = ControllerState#saga_controller_state.taskmap,
    SagaMod = ControllerState#saga_controller_state.saga_mod,
    GoalTasks = SagaMod:saga_complete(),
    {TasksPending} =
        lists:foldl(
            fun(TaskName, {IsCycleFinished}) ->
                case IsCycleFinished of
                    false ->
                        TaskState = maps:get(TaskName, TaskMap, #task_state{}),
                        case TaskState#task_state.status of
                            created ->
                                case process_saga_task_internal(SagaRec, TaskName) of
                                    ok -> {false};
                                    {error, processing_function_unknown} ->
                                        {true}
                                end;
                            completed ->
                                {false};
                            _ ->
                                {true}
                        end;
                    true ->
                        {true}
                end
            end,
            {false},
        GoalTasks),
    case TasksPending of
        true ->
            ok;
        false ->
            %% SAGA FINISHED
            update_saga_status(SagaId, completed),
            ok
    end.

%% @doc updates status for a particular task
%% status can be created/processing/failed
-spec update_task_status(integer(), atom(), atom()) -> term().
update_task_status(SagaId, TaskName, NewStatus) ->
    {ok, SagaRec} = get_by_id(SagaId),
    ControllerState = SagaRec#gen_saga_persist.controller_state,
    TaskMap = ControllerState#saga_controller_state.taskmap,
    TaskState = maps:get(TaskName, TaskMap),
    UpdatedTaskMap = TaskMap#{TaskName => TaskState#task_state{status = NewStatus}},
    UpdatedControllerState = ControllerState#saga_controller_state{taskmap = UpdatedTaskMap},
    create_or_update(SagaId, SagaRec#gen_saga_persist{controller_state = UpdatedControllerState}, []).

%% @doc updates status of the top level saga
-spec update_saga_status(integer(), atom()) -> term().
update_saga_status(SagaId, NewStatus) ->
    {ok, SagaRec} = get_by_id(SagaId),
    create_or_update(SagaId, SagaRec#gen_saga_persist{status = NewStatus}, []).

%% @doc overwrite an existing saga
-spec create_or_update(integer(), term(), list()) -> term().
create_or_update(SagaId, SagaRec, Metadata) ->
    {atomic, Result} = ?MNESIA_TRANSACTION(
        fun() ->
            case baseinfo:create(?MODEL, SagaId, SagaRec, Metadata) of
            {ok, Key} ->
                {ok, Key};
            Else ->
                Else
            end
        end),
    Result.

%% @doc fetches an existing saga using its ID
-spec get_by_id(integer()) -> term().
get_by_id(SagaId) ->
    {atomic, Result} = ?MNESIA_TRANSACTION(
        fun() ->
            baseinfo:get_by_id(?MODEL, SagaId)
        end),
    Result.

%% @doc gets status of a saga
-spec get_status(integer()) -> atom().
get_status(SagaId) ->
    {ok, SagaRec} = get_by_id(SagaId),
    SagaRec#gen_saga_persist.status.

%% @doc gets all sagas defined as a list
-spec get_all() -> list().
get_all() ->
    {atomic, Result} = ?MNESIA_TRANSACTION(
        fun() ->
            baseinfo:get_all(?MODEL)
        end),
    Result.

%% @doc search_by implemented on gen_saga model
-spec search_by(list(), list()) -> term().
search_by(WhereClauseList, ColumnList) ->
    baseinfo:search_by(?MODEL, WhereClauseList, ColumnList).

%% @doc delete a particular saga using its id
-spec delete(integer()) -> term().
delete(SagaId) ->
    baseinfo:delete(?MODEL, SagaId).

%% @doc deletes all the sagas in the system
-spec delete_all() -> term().
delete_all() ->
    baseinfo:delete_all(?MODEL).

%% @doc processes a particular task in a saga
%% resumes saga once the task is complete
-spec process_saga_task(integer(), atom()) -> term().
process_saga_task(SagaId, TaskName) ->
    {ok, SagaRec} = get_by_id(SagaId),
    process_saga_task_internal(SagaRec, TaskName),
    process_saga(SagaId).

%% @doc marks a saga task as complete and resume saga post that
-spec mark_saga_task_complete(integer(), atom()) -> term().
mark_saga_task_complete(SagaId, TaskName) ->
    update_task_status(SagaId, TaskName, completed),
    process_saga(SagaId).

%% @doc marks a saga task as failed
-spec mark_saga_task_failed(integer(), atom()) -> term().
mark_saga_task_failed(SagaId, TaskName) ->
    update_task_status(SagaId, TaskName, failed),
    update_saga_status(SagaId, failed).

%% INTERNAL FUNCTIONS

process_saga_task_internal(SagaRec, TaskName) when is_record(SagaRec, gen_saga_persist) ->
    SagaId = SagaRec#gen_saga_persist.id,
    ControllerState = SagaRec#gen_saga_persist.controller_state,
    SagaMod = ControllerState#saga_controller_state.saga_mod,
    SagaState = ControllerState#saga_controller_state.saga_state,
    ProcessFunName = list_to_atom("process_" ++ atom_to_list(TaskName)),
    case erlang:function_exported(SagaMod, ProcessFunName, 2) of
        true ->
            update_task_status(SagaId, TaskName, processing),
            SagaMod:ProcessFunName(SagaId, SagaState),
            update_task_status(SagaId, TaskName, completed),
            ok;
        false ->
            {error, processing_function_unknown}
    end.

%% Unit Tests

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

gen_saga_sync_execute_test_() ->
    {
        setup,
        fun() ->
           ok
        end,
        fun(_)->
            meck:unload(),
            gen_saga:delete_all()
        end,
        [
            {"Testing sync saga completion",
                ?_assertEqual(
                    ok,
                    element(1, gen_saga:init(test_saga, [x]))
                )
            }
        ]
    }.

gen_saga_async_execute_test_() ->
    {
        setup,
        fun() ->
           {ok, SagaId} = gen_saga:init(test_saga, [x]),
           gen_saga:mark_saga_task_complete(SagaId, async_task),
           SagaId
        end,
        fun(_)->
            meck:unload(),
            gen_saga:delete_all()
        end,
        fun(SagaId) ->
            [
                {"Testing sync saga completion",
                    ?_assertEqual(completed,
                        gen_saga:get_status(SagaId))
                },
                {"Testing saga deletion",
                    ?_assertEqual(ok,
                        gen_saga:delete(SagaId))
                }
            ]
        end
    }.

-endif.
