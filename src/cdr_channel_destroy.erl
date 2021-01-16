%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2021, 2600Hz
%%% @doc Listen for CDR events and record them to the database
%%% @author James Aimonetti
%%% @author Edouard Swiac
%%% @author Ben Wann
%%% @author Sponsored by GTNetwork LLC, Implemented by SIPLABS LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cdr_channel_destroy).

-export([handle_req/2]).

-include("cdr.hrl").

-define(IGNORED_APP, kapps_config:get(?CONFIG_CAT, <<"ignore_apps">>, [<<"milliwatt">>])).

-define(LOOPBACK_KEY, <<"ignore_loopback_bowout">>).
-define(IGNORE_LOOPBACK(AccountId),
        case AccountId of
            'undefined' -> kapps_config:get_is_true(?CONFIG_CAT, ?LOOPBACK_KEY, 'true');
            _ -> kapps_account_config:get_global(AccountId, ?CONFIG_CAT, ?LOOPBACK_KEY, 'true')
        end).

-define(CHANNEL_VARS, <<"Custom-Channel-Vars">>).
-define(CCV(Key), [?CHANNEL_VARS, Key]).

-spec handle_req(kz_call_event:payload(), kz_term:proplist()) -> 'ok'.
handle_req(JObj, _Props) ->
    'true' = kapi_call:event_v(JObj),
    _ = kz_log:put_callid(JObj),
    Routines = [fun maybe_ignore_app/1
               ,fun maybe_ignore_loopback/1
               ],
    case lists:foldl(fun maybe_ignore_cdr/2, {JObj, []}, Routines) of
        {_, []} -> handle_req(JObj);
        {_, List} ->
            lists:foreach(fun(M) -> lager:debug("~s", [M]) end, List)
    end.

-spec maybe_ignore_cdr(fun(), {kz_call_event:payload(), list()}) -> {kz_call_event:payload(), list()}.
maybe_ignore_cdr(Fun, {JObj, Acc}) ->
    case Fun(JObj) of
        {'true', M} -> {JObj, [M | Acc]};
        _ -> {JObj, Acc}
    end.

-spec maybe_ignore_app(kz_call_event:payload()) -> {boolean(), binary()}.
maybe_ignore_app(JObj) ->
    AppName = kz_term:to_binary(kz_call_event:application_name(JObj)),
    {lists:member(AppName, ?IGNORED_APP)
    ,<<"ignoring cdr request from ", AppName/binary>>
    }.

-spec maybe_ignore_loopback(kz_call_event:payload()) -> {boolean(), binary()}.
maybe_ignore_loopback(JObj) ->
    {kz_term:is_true(?IGNORE_LOOPBACK(kz_call_event:account_id(JObj)))
     andalso kz_json:is_true(<<"Channel-Is-Loopback">>, JObj)
     andalso kz_json:is_true(<<"Channel-Loopback-Bowout">>, JObj)
     andalso kz_json:is_true(<<"Channel-Loopback-Bowout-Execute">>, JObj)
     andalso (is_normal_hangup_cause(kz_call_event:hangup_cause(JObj))
              orelse kz_json:get_ne_binary_value(<<"Channel-Loopback-Leg">>, JObj) =/= <<"B">>
             ),
     <<"ignoring cdr request for loopback channel">>
    }.

-spec is_normal_hangup_cause(kz_term:api_ne_binary()) -> boolean().
is_normal_hangup_cause('undefined') -> 'true';
is_normal_hangup_cause(<<"NORMAL", _/binary>>) -> 'true';
is_normal_hangup_cause(_) -> 'false'.

-spec handle_req(kz_call_event:payload()) -> 'ok'.
handle_req(JObj) ->
    AccountId = kz_call_event:account_id(JObj),
    Timestamp = kz_call_event:timestamp(JObj),
    save_cdr(cdr_util:prepare_save_channel_destroy(AccountId, Timestamp, JObj)).

-spec save_cdr(kz_call_event:payload()) -> 'ok'.
save_cdr(JObj) ->
    CDRDb = kz_doc:account_db(JObj),
    case cdr_util:save_cdr(CDRDb, kz_json:normalize_jobj(JObj)) of
        {'error', 'max_save_retries'} ->
            lager:error("write failed to ~s, too many retries", [CDRDb]);
        'ok' -> 'ok'
    end.
