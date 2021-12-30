%%%-------------------------------------------------------------------
%% @doc gen_saga public API
%% @end
%%%-------------------------------------------------------------------

-module(gen_saga_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    gen_saga_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
