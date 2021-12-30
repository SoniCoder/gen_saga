-record(task_state, {
    status = created
}).

-record(saga_controller_state, {
    saga_mod,
    taskmap,
    saga_state
}).

-record(gen_saga_persist, {
    id :: integer(), %% unique id of the saga
    partition :: integer(), %% partition allocated to the saga
    app :: atom(), %% app which created this saga ... is undefined if app is not a part of the pool
    type, %% user defined type
    subtype, %% user defined subtype
    name, %% user defined name
    status, %% status of the saga .. can be - created/processing/failed
    execution_type, %% can be manual or auto for automatic saga
    retry_count, %% number of times this saga has been retried
    update_time, %% last time this saga was updated
    controller_state %% internal state of the saga .. stores status of various tasks, etc.
}).


-type saga_id() :: string().
