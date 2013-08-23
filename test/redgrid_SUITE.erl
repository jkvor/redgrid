-module(redgrid_SUITE).

%% API
-export([all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

%% Test cases
-export([regular_start/1]).
-export([no_fail_start/1, reconnect_success/1, no_fail_register_node/1,
         no_fail_connect_nodes/1]).

-include_lib("common_test/include/ct.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [regular_start, {group, disconnection}].

groups() ->
    [{disconnection, [],
      [no_fail_start, reconnect_success,
       no_fail_register_node, no_fail_connect_nodes]}].

init_per_suite(Config) ->
    application:load(redgrid),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(disconnection, Config) ->
    %% Give an invalid REDIS_URL value. The lookup is done
    %% by first checking if the value has been cached in the app
    %% config and then going for the OS. We can quickly overwrite
    %% values and be done with it.
    NewConf = case application:get_env(redgrid, redis_url) of
        undefined ->
            [{original_redis_url, undefined} | Config];
        {ok, Url} ->
            [{original_redis_url, Url} | Config]
    end,
    application:set_env(redgrid, redis_url, "redis://badhost:9999"),
    NewConf;
init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    case proplists:get_value(original_redis_url, Config, not_found) of
        not_found -> ok;
        Value -> application:set_env(redgrid, redis_url, Value)
    end.

init_per_testcase(reconnect_success, Config) ->
    %% Because we change the config at runtime in this test we have to
    %% roll it back after the fact.
    {ok, GroupRedgrid} = application:get_env(redgrid, redis_url),
    [{group_redgrid, GroupRedgrid} | Config];
init_per_testcase(_TestCase, Config) ->
    ct:pal("Conf: ~p", [application:get_all_env(redgrid)]),
    Config.

end_per_testcase(reconnect_success, Config) ->
    %% Because we change the config at runtime in this test we have to
    %% roll it back after the fact.
    GroupRedgrid = ?config(group_redgrid, Config),
    application:set_env(redgrid, redis_url, GroupRedgrid);
end_per_testcase(_TestCase, _Config) ->
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================
regular_start(_Config) ->
    {ok, Pid} = redgrid:start_link(),
    true = is_pid(element(2, get_state(Pid))), % redis_cli field
    unlink(Pid),
    exit(Pid, shutdown).


no_fail_start(_Config) ->
    %% An application that cannot connect at boot time does not result
    %% in a direct failure. This test relies on a R16B01 feature to look
    %% at the process state.
    {ok, Pid} = redgrid:start_link(),
    State = get_state(Pid),
    undefined = element(2, State), % redis_cli field
    unlink(Pid),
    exit(Pid, shutdown).

reconnect_success(Config) ->
    %% This also tests configuration reloading.
    {ok, Pid} = redgrid:start_link(),
    undefined = element(2, get_state(Pid)), % redis_cli field
    %% we have a 1s reconnect by default. Let it fail
    timer:sleep(1050),
    undefined = element(2, get_state(Pid)), % redis_cli field
    %% Exponential backoff gives us ~2s to reconnect
    application:set_env(redgrid, redis_url,
                        ?config(original_redis_url, Config)),

    {ok,no_delete} = redgrid:suspend(),
    ok = redgrid:reload_config(),
    ok = redgrid:resume(),
    timer:sleep(2100),
    true = is_pid(element(2, get_state(Pid))), % redis_cli field
    unlink(Pid),
    exit(Pid, shutdown).

no_fail_register_node(_Config) ->
    {ok, Pid} = redgrid:start_link(),
    undefined = element(2, get_state(Pid)), % redis_cli field
    Pid ! register_node,
    timer:sleep(3000),
    true = erlang:is_process_alive(Pid),
    unlink(Pid),
    exit(Pid, shutdown).

no_fail_connect_nodes(_Config) ->
    {ok, Pid} = redgrid:start_link(),
    undefined = element(2, get_state(Pid)), % redis_cli field
    Pid ! connect_nodes,
    timer:sleep(3000),
    true = erlang:is_process_alive(Pid),
    unlink(Pid),
    exit(Pid, shutdown).

get_state(Proc) ->
    try
        sys:get_state(Proc)
    catch
        error:undef ->
            case sys:get_status(Proc) of
                {status,_Pid,{module,gen_server},Data} ->
                    {data, Props} = lists:last(lists:nth(5, Data)),
                    proplists:get_value("State", Props);
                {status,_Pod,{module,gen_fsm},Data} ->
                    {data, Props} = lists:last(lists:nth(5, Data)),
                    proplists:get_value("StateData", Props)
            end
    end.
