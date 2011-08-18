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

## ENV VARS

LOCAL\_IP
DOMAIN
VERSION
