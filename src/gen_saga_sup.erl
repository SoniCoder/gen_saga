%%%-------------------------------------------------------------------
%% @doc gen_saga top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(gen_saga_sup).

-behaviour(supervisor3).

-export([start_link/0]).

-export([init/1, post_init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor3:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    GenSagaPoolSup = {gen_saga_pool_sup, {gen_saga_pool_sup, start_link, []},
                    {permanent, 30}, infinity, supervisor, [gen_saga_pool_sup]},

    GenSagaPoolOrganiser = {gen_saga_pool_organiser, {gen_saga_pool_organiser, start_link, []},
                    {permanent, 30}, 2000, worker, [gen_saga_pool_organiser]},

    Procs = [GenSagaPoolSup, GenSagaPoolOrganiser],
    {ok, {{one_for_one, 1, 5}, Procs}}.

post_init([]) -> ignore.
%% internal functions