-module(test_saga).

-compile(export_all).

-record(state, {
    x
}).

init([X]) ->
    {ok, #state{x = X},
        #{type => test_transaction, subtype =>
            {test_transaction, 1}}}.

saga_tasks() ->
    [
        task1,
        task2,
        async_task
    ].

process_task1(_SagaId, _State) ->
    ok.

task1(depends) -> [].

process_task2(_SagaId, _State) ->
    ok.

task2(depends) -> [].

task3(depends) -> [].

saga_complete() ->
    [task1, task2, async_task].
