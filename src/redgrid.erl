-module(redgrid).

-export([update_meta/1, update_meta/2,
         nodes/0, nodes/1]).


update_meta(Meta) ->
    redgrid_srv:update_meta(Meta).

update_meta(NameOrPid, Meta)  ->
    redgrid_srv:update_meta(NameOrPid, Meta).

nodes() ->
    redgrid_srv:nodes().

nodes(NameOrPid) ->
    redgrid_srv:nodes(NameOrPid).
