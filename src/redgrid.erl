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

-export([start_link/0, start_link/1, update_meta/1, nodes/0,
         suspend/0, resume/0, reload_config/0]).

-record(state, {redis_cli, opts, bin_node, ip, domain, version, meta, nodes=[],
                status=normal, backoff}).

start_link() ->
    start_link([]).

start_link(Meta) when is_list(Meta) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Meta], []).

update_meta(Meta) when is_list(Meta) ->
    gen_server:cast(?MODULE, {update_meta, Meta}).

nodes() ->
    gen_server:call(?MODULE, nodes, 5000).

-spec suspend() -> 'ok' | {'ok', 'no_delete'}.
suspend() ->
    gen_server:call(?MODULE, suspend, 5000).

resume() ->
    gen_server:call(?MODULE, resume, 5000).

%% This function reloads configuration and then resets the connection.
%% It however expects the correct config value to already be in memory
%% in application:env vars, and will not seek to disk for such information.
%% A seek to disk can be forced by manually unsetting the configuration as
%% application:set_env(redgrid, redis_url, undefined).
%%
%% For this call to succeed, the redgrid process must be suspended.
-spec reload_config() -> 'ok' | {'error', Reason::term()}.
reload_config() ->
    gen_server:call(?MODULE, reload_config, 5000).

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
init([Meta]) ->
    process_flag(trap_exit, true),
    Opts = redis_opts(),
    log(debug, "Redis opts: ~p~n", [Opts]),
    {_Status, State} = redo_connect(#state{opts=Opts, backoff=backoff()}),
    BinNode = atom_to_binary(node(), utf8),
    Ip = local_ip(),
    Domain = domain(),
    Version = version(),
    log(debug, "State: node=~s ip=~s domain=~s version=~s~n", [BinNode, Ip, Domain, Version]),
    {ok, State#state{opts=Opts,
                     bin_node = BinNode,
                     ip = Ip,
                     domain = Domain,
                     version = Version,
                     meta = Meta}, 0}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%    {reply, Reply, State, Timeout} |
%%    {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, Reply, State} |
%%    {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(suspend, _From, State = #state{redis_cli=Pid}) ->
    %% We can be suspended without having had time to
    %% delete our own entry due to not being connected. In such a
    %% case, we may want to notify the receiver of what is going on
    %% so that they are more careful.
    case Pid of
        undefined ->
            {reply, {ok,no_delete}, State#state{status=suspended}};
        Pid when is_pid(Pid) ->
            ok = unregister_node(State),
            {reply, ok, State#state{status=suspended}}
    end;

handle_call(resume, _From, S=#state{status=suspended}) ->
    self() ! register_node,
    self() ! connect_nodes,
    {reply, ok, S#state{status=normal}};

handle_call(nodes, _From, #state{ip=Ip, meta=Meta, nodes=Nodes}=State) ->
    Node = {node(), [<<"ip">>, to_bin(Ip) | [to_bin(M) || M <- Meta]]},
    {reply, [Node|Nodes], State};

handle_call(reload_config, _From, S = #state{status=normal}) ->
    {reply, {error, redgrid_must_be_suspended}, S};
handle_call(reload_config, _From, S = #state{status=suspended}) ->
    log(info, "Reloading redis config.~n",[]),
    Opts = redis_opts(),
    log(debug, "Redis opts: ~p~n", [Opts]),
    {_Status, State} = redo_connect(S#state{opts=Opts, backoff=backoff()}),
    BinNode = atom_to_binary(node(), utf8),
    Ip = local_ip(),
    Domain = domain(),
    Version = version(),
    {reply, ok, State#state{bin_node=BinNode,
                            ip=Ip,
                            domain=Domain,
                            version=Version}};


handle_call(_Msg, _From, State = #state{}) ->
    {reply, unknown_message, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({update_meta, Meta}, State = #state{status=suspended}) ->
    State1 = State#state{meta=Meta},
    {noreply, State1};
handle_cast({update_meta, Meta}, State = #state{redis_cli=undefined}) ->
    State1 = State#state{meta=Meta},
    {noreply, State1};
handle_cast({update_meta, Meta}, State = #state{}) ->
    State1 = State#state{meta=Meta},
    ok = register_node(State1),
    {noreply, State1};


handle_cast(_Msg, State = #state{}) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(timeout, State) ->
    self() ! register_node,
    self() ! connect_nodes,
    {noreply, State};

handle_info(register_node, State = #state{redis_cli=undefined, status=normal}) ->
    %% Not currently connected. Skip ahead until reconnect.
    erlang:send_after(2000, self(), register_node),
    {noreply, State};
handle_info(register_node, State = #state{status=normal}) ->
    ok = register_node(State),
    erlang:send_after(2000, self(), register_node),
    {noreply, State};

handle_info(connect_nodes, State=#state{redis_cli=undefined, status=normal}) ->
    %% Not currently connected. Skip ahead until reconnect.
    erlang:send_after(2000, self(), connect_nodes),
    {noreply, State};
handle_info(connect_nodes,
            #state{redis_cli=Pid, domain=Domain, version=Version, status=normal}=State) ->
    case get_node_keys(Pid, Domain) of
        {error, Err} ->
            log(warning,
                "at=get_node_keys err=~p "
                "pid=~p domain=~p",
                [Err, Pid, Domain]),
            erlang:send_after(2000, self(), connect_nodes),
            {noreply, State};
        Keys ->
            Nodes = connect_nodes(Keys, Pid, Domain, Version),
            erlang:send_after(2000, self(), connect_nodes),
            {noreply, State#state{nodes=Nodes}}
    end;

handle_info({'EXIT', Pid, Reason}, State=#state{redis_cli=Pid}) ->
    log(warning,"at=handle_info err=exit reason=~p", [Reason]),
    {_Status, NewState} = redo_connect(State),
    {noreply, NewState};

handle_info({timeout, _Tref, reconnect_redo}, State=#state{}) ->
    {_Status, NewState} = redo_connect(State),
    {noreply, NewState};

handle_info(_Info, State = #state{}) ->
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
    if tuple_size(State) + 2 =:= tuple_size(#state{}) -> % oldest state
           {ok, list_to_tuple(tuple_to_list(State)++[normal, backoff()])};
       tuple_size(State) + 1 =:= tuple_size(#state{}) -> % older state
           {ok, list_to_tuple(tuple_to_list(State)++[backoff()])};
       tuple_size(State) =:= tuple_size(#state{}) -> % current?
           {ok, State}
    end.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
redo_connect(State=#state{redis_cli=Pid, opts=Opts, backoff=Backoff}) ->
    case is_pid(Pid) andalso erlang:is_process_alive(Pid) of
        true ->
            log(info, "shutting down old connection on reconnect~n", []),
            unlink(Pid), % we don't want 'EXIT' from this.
            exit(Pid, shutdown);
        false ->
            ok
    end,
    case redo:start_link(undefined, Opts) of
        % ignore -> not expected, let's crash!
        {error, Reason} ->
            Delay = backoff:fire(Backoff),
            log(error, "connection failed for reason ~p, retrying in ~pms~n",
                [Reason, Delay]),
            {_, NewBackoff} = backoff:fail(Backoff),
            {disconnected, State#state{redis_cli=undefined, backoff=NewBackoff}};
        {ok, NewPid} ->
            log(info, "reconnection successful.~n", []),
            {_, NewBackoff} = backoff:succeed(Backoff),
            {connected, State#state{redis_cli=NewPid, backoff=NewBackoff}}
    end.

get_node_keys(Pid, Domain) ->
    Val = iolist_to_binary([<<"redgrid:">>, Domain, <<":*">>]),
    redo:cmd(Pid, [<<"KEYS">>, Val]).

connect_nodes(Keys, Pid, Domain, Version) ->
    lists:foldl(fun(Key, Acc) ->
                        case connect(Pid, Key,
                                     length(Domain), length(Version)) of
                            undefined -> Acc;
                            Node -> [Node|Acc]
                        end
                end, [], Keys).

-spec connect(pid(), any(), any(), any()) -> 'undefined' | {atom(), list()}.
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
            undefined;
        false ->
            connect2(Pid, Key, StrNode, Node)
    end.

connect2(Pid, Key, StrNode, Node) ->
    case get_node(Pid, Key) of
        Props when is_list(Props) ->
            case proplists:get_value(<<"ip">>, Props) of
                undefined ->
                    log(debug, "Failed to retrieve IP from key props ~p~n", [Props]),
                    undefined;
                Ip ->
                    connect3(StrNode, Node, Ip, Props)
            end;
        Other ->
            log(debug, "Failed to lookup node ip with key ~s: ~p~n", [Key, Other]),
            undefined
    end.

connect3(StrNode, Node, Ip, Props) ->
    case inet:getaddr(binary_to_list(Ip), inet) of
        {ok, Addr} ->
            case re:run(StrNode, ".*@(.*)$", [{capture, all_but_first, list}]) of
                {match, [Host]} ->
                    connect4(Node, Addr, Host, Props);   
                Other ->
                    log(debug, "Failed to parse host ~s: ~p~n", [StrNode, Other]),
                    undefined
            end;
        Err ->
            log(debug, "Failed to resolve ip ~s: ~p~n", [Ip, Err]),
            undefined
    end.

connect4(Node, Addr, Host, Props) ->
    inet_db:add_host(Addr, [Host]),
    case net_adm:ping(Node) of
        pong ->
            log(debug, "Monitoring node ~p~n", [Node]),
            {Node, Props};
        pang ->
            log(debug, "Ping failed ~p ~s -> ~p~n", [Node, Addr, Host]),
            {Node, Props}
    end.

get_node(Pid, Key) ->
    case redo:cmd(Pid, [<<"HGETALL">>, Key]) of
        List when is_list(List) -> list_to_proplist(List);
        Err -> Err
    end.

register_node(#state{redis_cli=Pid, ip=Ip, domain=Domain, version=Version, bin_node=BinNode, meta=Meta}) ->
    Key = iolist_to_binary([<<"redgrid:">>, Domain, <<":">>, Version, <<":">>, BinNode]),
    Cmds = [["HMSET", Key, "ip", Ip | flatten_proplist(Meta)], ["EXPIRE", Key, "120"]],
    redo:cmd(Pid, Cmds),
    ok.

unregister_node(#state{redis_cli=Pid, domain=Domain, version=Version, bin_node=BinNode}) ->
    Key = iolist_to_binary([<<"redgrid:">>, Domain, <<":">>, Version, <<":">>, BinNode]),
    Cmds = [["DEL", Key]],
    redo:cmd(Pid, Cmds),
    ok.

backoff() ->
    backoff:init(timer:seconds(1), timer:seconds(120),
                 self(), reconnect_redo).

flatten_proplist(Props) ->
    flatten_proplist(Props, []).

flatten_proplist([], Acc) ->
    Acc;

flatten_proplist([{Key, Val}|Tail], Acc) ->
    flatten_proplist(Tail, [Key, Val | Acc]).

list_to_proplist(List) ->
    list_to_proplist(List, []).

list_to_proplist([], Acc) ->
    Acc;

list_to_proplist([Key, Val|Tail], Acc) ->
    list_to_proplist(Tail, [{Key, Val}|Acc]).

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

to_bin(List) when is_list(List) ->
    list_to_binary(List);

to_bin(Bin) when is_binary(Bin) ->
    Bin;

to_bin(Int) when is_integer(Int) ->
    to_bin(integer_to_list(Int)).

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

-spec log_to_int([char()] |
                 'debug' |
                 'info' |
                 'warning' |
                 'error' |
                 'fatal') -> 0..4.
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
