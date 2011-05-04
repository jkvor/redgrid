%% Copyright (c) 2011 Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
-module(redgrid).
-export([start_link/0, init/1, loop/4]).
-compile(export_all).

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
    Opts = redis_opts(),
    log(debug, "Redis opts: ~p~n", [Opts]),
    {ok, Pid} = redo:start_link(undefined, Opts),
    BinNode = atom_to_binary(node(), utf8),
    Ip = local_ip(),
    Domain = domain(),
    log(debug, "Loop args: node=~s ip=~s domain=~s~n", [BinNode, Ip, Domain]),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(Pid, BinNode, Ip, Domain).

loop(Pid, BinNode, Ip, Domain) ->
    register_node(Pid, BinNode, Ip, Domain),
    Keys = get_node_keys(Pid, Domain),
    [connect(Pid, Key, length(Domain)) || Key <- Keys],
    receive
        {nodedown, _Node} ->
            ok
    after 0 ->
        ok
    end,
    timer:sleep(5 * 1000),
    ?MODULE:loop(Pid, BinNode, Ip, Domain).

register_node(Pid, BinNode, Ip, Domain) ->
    Key = iolist_to_binary([<<"redgrid:">>, Domain, <<":">>, BinNode]),
    Cmd = [<<"SETEX">>, Key, <<"10">>, Ip],
    <<"OK">> = redo:cmd(Pid, Cmd).

get_node_keys(Pid, Domain) ->
    Val = iolist_to_binary([<<"redgrid:">>, Domain, <<":*">>]),
    redo:cmd(Pid, [<<"KEYS">>, Val]).

connect(Pid, Key, Size) ->
    case Key of
        <<"redgrid:", _:Size/binary, ":", BinNode/binary>> ->
            connect1(Pid, Key, binary_to_list(BinNode));
        _ ->
            log(debug, "Attempting to connect to invalid key: ~s~n", [Key])
    end.

connect1(Pid, Key, StrNode) ->
    Node = list_to_atom(StrNode),
    case node() == Node of
        true ->
            undefined;
        false ->
            case net_adm:ping(Node) of
                pong -> ok;
                pang -> connect2(Pid, Key, StrNode, Node)
            end
    end.

connect2(Pid, Key, StrNode, Node) ->
    case get_node(Pid, Key) of
        Ip when is_binary(Ip) ->
            connect3(StrNode, Node, Ip);
        Other ->
            log(debug, "Failed to lookup node ip with key ~s: ~p~n", [Key, Other])
    end.

connect3(StrNode, Node, Ip) ->
    case inet:getaddr(binary_to_list(Ip), inet) of
        {ok, Addr} ->
            case re:run(StrNode, ".*@(.*)$", [{capture, all_but_first, list}]) of
                {match, [Host]} ->
                    connect4(Node, Addr, Host);   
                Other ->
                    log(debug, "Failed to parse host ~s: ~p~n", [StrNode, Other])
            end;
        Err ->
            log(debug, "Failed to resolve ip ~s: ~p~n", [Ip, Err])
    end.

connect4(Node, Addr, Host) ->
    inet_db:add_host(Addr, [Host]),
    case net_adm:ping(Node) of
        pong ->
            log(debug, "Monitoring node ~p~n", [Node]),
            erlang:monitor_node(Node, true);
        pang ->
            log(debug, "Ping failed ~p ~s -> ~p~n", [Node, Addr, Host])
    end.

get_node(Pid, Key) ->
    redo:cmd(Pid, [<<"GET">>, Key]). 

redis_opts() ->
    RedisUrl = redis_url(),
    redo_uri:parse(RedisUrl).

redis_url() ->
    env_var(redis_url, "REDIS_URL", "redis://localhost:6379/").

local_ip() ->
    env_var(local_ip, "LOCAL_IP", "127.0.0.1").

domain() ->
    env_var(domain, "DOMAIN", "").

env_var(AppKey, EnvName, Default) ->
    case application:get_env(?MODULE, AppKey) of
        {ok, Val} -> Val;
        undefined ->
            case os:getenv(EnvName) of
                false -> Default;
                Val -> Val
            end
    end.

log(MsgLvl, Fmt, Args) when is_atom(MsgLvl); is_list(MsgLvl) ->
    log(log_to_int(MsgLvl), Fmt, Args);

log(MsgLvl, Fmt, Args) when is_integer(MsgLvl), is_list(Fmt), is_list(Args) ->
    SysLvl =
        case os:getenv("LOGLEVEL") of
            false -> 1;
            Val -> log_to_int(Val)
        end,
    MsgLvl >= SysLvl andalso error_logger:info_msg(Fmt, Args).

log_to_int(debug) -> 0;
log_to_int("debug") -> 0;
log_to_int("0") -> 0;
log_to_int(info) -> 1;
log_to_int("info") -> 1;
log_to_int("1") -> 1;
log_to_int(warning) -> 2;
log_to_int("warning") -> 2;
log_to_int("2") -> 2;
log_to_int(error) -> 3;
log_to_int("error") -> 3;
log_to_int("3") -> 3;
log_to_int(fatal) -> 4;
log_to_int("fatal") -> 4;
log_to_int("4") -> 4;
log_to_int(_) -> 1.
