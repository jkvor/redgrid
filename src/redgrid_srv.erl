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
-module(redgrid_srv).
-behaviour(gen_server).

-include_lib("alog_pt.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([start_link/0,
         update_meta/1, update_meta/2,
         nodes/0, nodes/1]).

-record(state, {pub_pid, sub_pid, pubsub_chan, sub_ref, bin_node,
                ip, domain, version, meta, nodes}).

start_link() ->
    case get_env_default(anonymous, false) of
        true ->
            gen_server:start_link(?MODULE, [], []);
        false ->
            gen_server:start_link({local, ?MODULE}, ?MODULE, [], [])
    end.



update_meta(Meta) when is_list(Meta) ->
    update_meta(?MODULE, Meta).

update_meta(NameOrPid, Meta) when is_list(Meta) ->
    gen_server:cast(NameOrPid, {update_meta, Meta}).

nodes() ->
    ?MODULE:nodes(?MODULE).

nodes(NameOrPid) ->
    gen_server:call(NameOrPid, nodes, 5000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%    {ok, State, Timeout}             |
%%    ignore                           |
%%    {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    Meta = get_env_default(meta, []),
    BinNode = atom_to_binary(node(), utf8),
    Ip = local_ip(),
    Domain = domain(),
    Version = version(),
    Url = get_env_default(url, "redis://localhost:6379/"),
    Opts = redo_uri:parse(Url),
    ?DBG({init, Opts}, [], [redgrid]),
    {ok, Pub} = redo:start_link(undefined, Opts),
    {ok, Sub} = redo:start_link(undefined, Opts),
    Chan = pubsub_channel(Domain, Version),
    Ref = redo:subscribe(Sub, Chan),
    ?DBG({init, Opts, BinNode, Ip, Domain, Version}, [], [redgrid]),
    {ok, #state{pub_pid = Pub,
                sub_pid = Sub,
                pubsub_chan = Chan,
                sub_ref = Ref,
                bin_node = BinNode,
                ip = Ip,
                domain = Domain,
                version = Version,
                meta = Meta,
                nodes = dict:new()}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%    {reply, Reply, State, Timeout} |
%%    {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, Reply, State} |
%%    {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(nodes, _From, #state{ip=Ip, meta=Meta, nodes=Nodes}=State) ->
    Node = {node(), [<<"ip">>, to_bin(Ip) | [to_bin(M) || M <- Meta]]},
    {reply, [Node|dict:to_list(Nodes)], State};

handle_call(_Msg, _From, State) ->
    {reply, unknown_message, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({update_meta, Meta}, State) ->
    State1 = State#state{meta=Meta},
    ok = register_node(State1),
    {noreply, State1};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%    {noreply, State, Timeout} |
%%    {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({Ref, [<<"subscribe">>, Chan, _Subscribers]}, #state{sub_ref=Ref, pubsub_chan=Chan}=State) ->
    self() ! register,
    ping_nodes(State),
    {noreply, State};


handle_info({Ref, [<<"message">>, Chan, <<"ping">>]}, #state{sub_ref=Ref, pubsub_chan=Chan}=State) ->
    ok = register_node(State),
    {noreply, State};

handle_info({Ref, [<<"message">>, Chan, Key]}, #state{sub_ref=Ref, pubsub_chan=Chan, pub_pid=Pid, domain=Domain, version=Version, nodes=Nodes}=State) ->
    case connect(Pid, Key, length(Domain), length(Version)) of
        undefined ->
            {noreply, State};
        {Node, Meta} ->
            Nodes1 = dict:store(Node, Meta, Nodes),
            {noreply, State#state{nodes=Nodes1}}
    end;

handle_info(register, State) ->
    ok = register_node(State),
    erlang:send_after(10000, self(), register),
    {noreply, State};

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
register_node(#state{pub_pid=Pid, pubsub_chan=Chan, ip=Ip, domain=Domain, version=Version, bin_node=BinNode, meta=Meta}) ->
    Key = iolist_to_binary([<<"redgrid:">>, Domain, <<":">>, Version, <<":">>, BinNode]),
    Cmds = [["HMSET", Key, "ip", Ip | flatten_proplist(Meta)], ["EXPIRE", Key, "60"]],
    [<<"OK">>, 1] = redo:cmd(Pid, Cmds),
    redo:cmd(Pid, ["PUBLISH", Chan, Key]),
    ok.

ping_nodes(#state{pub_pid=Pid, pubsub_chan=Chan}) ->
    redo:cmd(Pid, ["PUBLISH", Chan, "ping"]),
    ok.

connect(Pid, Key, DomainSize, VersionSize) ->
    case Key of
        <<"redgrid:", _:DomainSize/binary, ":", _:VersionSize/binary, ":", BinNode/binary>> ->
            connect1(Pid, Key, binary_to_list(BinNode));
        _ ->
	    ?ERROR({connect, "Invalid key", Key}, [], [redgrid]),
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
		    ?WARNING({connect2, "Failed to retrieve IP", Props}, [], [redgrid]),
                    undefined;
                Ip ->
                    connect3(StrNode, Node, Ip, Props)
            end;
        Other ->
	    ?WARNING({connect2, "Failed to lookup node ip with key", Key, Other}, [], [redgrid]),
            undefined
    end.

connect3(StrNode, Node, Ip, Props) ->
    case inet:getaddr(binary_to_list(Ip), inet) of
        {ok, Addr} ->
            case re:run(StrNode, ".*@(.*)$", [{capture, all_but_first, list}]) of
                {match, [Host]} ->
                    connect4(Node, Addr, Host, Props);   
                Other ->
		    ?WARNING({connect3, "Failed to parse host", StrNode, Other}, [], [redgrid]),
                    undefined
            end;
        Err ->
	    ?WARNING({connect3, "Failed to resolve ip", Ip, Err}, [], [redgrid]),
            undefined
    end.

connect4(Node, Addr, Host, Props) ->
    inet_db:add_host(Addr, [Host]),
    case net_adm:ping(Node) of
        pong ->
	    ?DBG({connect4, monitoring, Node}, [], [redgrid]),
            erlang:monitor_node(Node, true),
            {Node, Props};
        pang ->
	    ?WARNING({connect4, "Ping failed", Node, Addr, Host}, [], [redgrid]),
            {Node, Props}
    end.

get_node(Pid, Key) ->
    case redo:cmd(Pid, [<<"HGETALL">>, Key]) of
        List when is_list(List) -> list_to_proplist(List);
        Err -> Err
    end.

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

local_ip() ->
    get_env_default(local_ip, "127.0.0.1").

domain() ->
    get_env_default(domain, "").

version() ->
    get_env_default(version, "").


pubsub_channel(Domain, Version) ->
    iolist_to_binary([<<"redgrid:">>, Domain, <<":">>, Version]).

to_bin(List) when is_list(List) ->
    list_to_binary(List);

to_bin(Bin) when is_binary(Bin) ->
    Bin;

to_bin(Atom) when is_atom(Atom) ->
    to_bin(atom_to_list(Atom));

to_bin(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([to_bin(T) || T <- tuple_to_list(Tuple)]);

to_bin(Int) when is_integer(Int) ->
    to_bin(integer_to_list(Int)).

get_env_default(Key, Default) ->
    case  application:get_env(Key) of
	{ok, Res} ->
	    Res;
	_ ->
	    Default
    end.
