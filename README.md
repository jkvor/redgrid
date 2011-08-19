## About

Redgrid performs automatic Erlang node discovery through a shared Redis pub/sub channel.

## Build

    $ make

## Run

#### Start Redgrid with no arguments
    
    $ erl -pa ebin deps/*/ebin
    1> redgrid:start_link().
    {ok,<0.33.0>}
    2> whereis(redgrid).
    <0.33.0>

#### Start Redgrid with custom Redis url

    $ erl -pa ebin deps/*/ebin
    1> redgrid:start_link([{redis_url, "redis://localhost:6379/"}]).
    {ok,<0.33.0>}

#### Start Redgrid as a non-registered (anonymous) process

    $ erl -pa ebin deps/*/ebin
    1> redgrid:start_link([anonymous]).
    {ok,<0.33.0>}

#### Start with arbitrary meta data

    $ erl -pa ebin deps/*/ebin
    1> redgrid:start_link([{<<"foo">>, <<"bar">>}]).
    {ok,<0.33.0>}

## Example

#### TAB 1

Start **foo** node

    $ erl -pa ebin deps/*/ebin -name foo@`hostname`
    (foo@Jacob-Vorreuters-MacBook-Pro.local)1> redgrid:start_link().
    {ok,<0.39.0>}

#### TAB 2

Start **bar** node

    $ erl -pa ebin deps/*/ebin -name bar@`hostname`
    (bar@Jacob-Vorreuters-MacBook-Pro.local)1> redgrid:start_link().
    {ok,<0.39.0>}

View registered nodes

    (bar@Jacob-Vorreuters-MacBook-Pro.local)2> redgrid:nodes().
    [{'bar@Jacob-Vorreuters-MacBook-Pro.local',[<<"ip">>, <<"localhost">>]},
     {'foo@Jacob-Vorreuters-MacBook-Pro.local',[{<<"ip">>, <<"localhost">>}]}]
    (bar@Jacob-Vorreuters-MacBook-Pro.local)3> [node()|nodes()].
    ['bar@Jacob-Vorreuters-MacBook-Pro.local', 'foo@Jacob-Vorreuters-MacBook-Pro.local']

Update meta data for **bar** node

    (bar@Jacob-Vorreuters-MacBook-Pro.local)4> redgrid:update_meta([{weight, 50}]).
    ok

#### TAB 1

View registered nodes (including updated meta data for **bar**)

    (foo@Jacob-Vorreuters-MacBook-Pro.local)2> redgrid:nodes().
    [{'foo@Jacob-Vorreuters-MacBook-Pro.local',[<<"ip">>, <<"localhost">>]},
     {'bar@Jacob-Vorreuters-MacBook-Pro.local',[{<<"ip">>,<<"localhost">>},
                                                {<<"weight">>, <<"50">>}]}]


## ENV VARS

    LOCAL_IP: The IP written to Redis to which other nodes will attempt to connect
    DOMAIN: Used to build Redis key and channel names
    VERSION: Used to build Redis key and channel names
