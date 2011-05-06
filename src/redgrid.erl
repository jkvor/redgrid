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
-behaviour(gen_server).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([start_link/0, register_node/0, connect_nodes/0, registered_nodes/0]).

-record(state, {redis_cli, bin_node, ip, domain, version, nodes=[]}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register_node() ->
    gen_server:cast(?MODULE, register_node),
    timer:sleep(2000),
    register_node().

connect_nodes() ->
    gen_server:cast(?MODULE, connect_nodes),
    timer:sleep(2000),
    connect_nodes().

registered_nodes() ->
    gen_server:call(?MODULE, registered_nodes, 5000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%    {ok, State, Timeout} |
%%    ignore                             |
%%    {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    Opts = redis_opts(),
    log(debug, "Redis opts: ~p~n", [Opts]),
    {ok, Pid} = redo:start_link(undefined, Opts),
    BinNode = atom_to_binary(node(), utf8),
    Ip = local_ip(),
    Domain = domain(),
    Version = version(),
    log(debug, "State: node=~s ip=~s domain=~s version=~s~n", [BinNode, Ip, Domain, Version]),
    spawn_link(fun register_node/0),
    spawn_link(fun connect_nodes/0),
    {ok, #state{redis_cli = Pid,
                bin_node = BinNode,
                ip = Ip,
                domain = Domain,
                version = Version}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%    {reply, Reply, State, Timeout} |
%%    {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, Reply, State} |
%%    {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(registered_nodes, _From, #state{nodes=Nodes}=State) ->
    {reply, Nodes, State};

handle_call(_Msg, _From, State) ->
    {reply, unknown_message, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(register_node, #state{redis_cli=Pid, ip=Ip, domain=Domain, version=Version, bin_node=BinNode}=State) ->
    Key = iolist_to_binary([<<"redgrid:">>, Domain, <<":">>, Version, <<":">>, BinNode]),
    Cmd = [<<"SETEX">>, Key, <<"6">>, Ip],
    <<"OK">> = redo:cmd(Pid, Cmd),
    {noreply, State};

handle_cast(connect_nodes, #state{redis_cli=Pid, domain=Domain, version=Version}=State) ->
    Keys = get_node_keys(Pid, Domain),
    Nodes = lists:foldl(
        fun(Key, Acc) ->
            case connect(Pid, Key, length(Domain), length(Version)) of
                undefined -> Acc;
                Node -> [Node|Acc]
            end
        end, [], Keys),
    {noreply, State#state{nodes=Nodes}};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
get_node_keys(Pid, Domain) ->
    Val = iolist_to_binary([<<"redgrid:">>, Domain, <<":*">>]),
    redo:cmd(Pid, [<<"KEYS">>, Val]).

connect(Pid, Key, DomainSize, VersionSize) ->
    case Key of
        <<"redgrid:", _:DomainSize/binary, ":", _:VersionSize/binary, ":", BinNode/binary>> ->
            connect1(Pid, Key, binary_to_list(BinNode));
        _ ->
            log(debug, "Attempting to connect to invalid key: ~s~n", [Key]),
            undefined
    end.

connect1(Pid, Key, StrNode) ->
    Node = list_to_atom(StrNode),
    case node() == Node of
        true ->
            node();
        false ->
            case net_adm:ping(Node) of
                pong -> Node;
                pang -> connect2(Pid, Key, StrNode, Node)
            end
    end.

connect2(Pid, Key, StrNode, Node) ->
    case get_node(Pid, Key) of
        Ip when is_binary(Ip) ->
            connect3(StrNode, Node, Ip);
        Other ->
            log(debug, "Failed to lookup node ip with key ~s: ~p~n", [Key, Other]),
            undefined
    end.

connect3(StrNode, Node, Ip) ->
    case inet:getaddr(binary_to_list(Ip), inet) of
        {ok, Addr} ->
            case re:run(StrNode, ".*@(.*)$", [{capture, all_but_first, list}]) of
                {match, [Host]} ->
                    connect4(Node, Addr, Host);   
                Other ->
                    log(debug, "Failed to parse host ~s: ~p~n", [StrNode, Other]),
                    undefined
            end;
        Err ->
            log(debug, "Failed to resolve ip ~s: ~p~n", [Ip, Err]),
            undefined
    end.

connect4(Node, Addr, Host) ->
    inet_db:add_host(Addr, [Host]),
    case net_adm:ping(Node) of
        pong ->
            log(debug, "Monitoring node ~p~n", [Node]),
            erlang:monitor_node(Node, true),
            Node;
        pang ->
            log(debug, "Ping failed ~p ~s -> ~p~n", [Node, Addr, Host]),
            Node
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

version() ->
    env_var(version, "VERSION", "").

env_var(AppKey, EnvName, Default) ->
    case application:get_env(?MODULE, AppKey) of
        {ok, Val} when is_list(Val); is_binary(Val) -> Val;
        _ ->
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
