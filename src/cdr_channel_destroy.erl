%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
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

-spec handle_req(kz_call_event:payload(), kz_term:proplist()) -> 'ok'.
handle_req(JObj, _Props) ->
    'true' = kapi_call:event_v(JObj),
    _ = kz_log:put_callid(JObj),
    Routines = [fun maybe_ignore_app/1
               ,fun maybe_ignore_loopback/1
               ],
    case lists:foldl(fun(F, Acc) -> maybe_ignore_cdr(F, Acc, JObj) end, [], Routines) of
        [] -> handle_req(JObj);
        List ->
            lists:foreach(fun(M) -> lager:debug("~s", [M]) end, List)
    end.

-spec maybe_ignore_cdr(fun(), kz_term:ne_binaries(), kz_call_event:payload()) ->
          kz_term:ne_binaries().
maybe_ignore_cdr(Fun, Acc, JObj) ->
    case Fun(JObj) of
        {'true', M} -> [M | Acc];
        _ -> Acc
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
    prepare_and_save(AccountId, Timestamp, JObj).

-spec prepare_and_save(account_id(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> 'ok'.
prepare_and_save(AccountId, Timestamp, JObj) ->
    %% Caution: The Timestamp is ahead of interaction-timestamp.
    %%          {@link set_interaction/3} is setting Id based on interaction-timestamp.
    %%          So there is an edge case for the midnight between two months. If interaction time is less than midnight
    %%          and Timestamp is falling to after midnight (which is next month) the document ends up in the next month MODB
    %%          but the document ID is for previous month. Which breaks cb_cdrs and interaction view.

    Routines = [fun cdr_util:update_ccvs/3
               ,fun cdr_util:set_doc_id/3
               ,fun cdr_util:set_recording_url/3
               ,fun cdr_util:set_call_priority/3
               ,fun cdr_util:maybe_set_e164_destination/3
               ,fun cdr_util:maybe_set_e164_origination/3
               ,fun cdr_util:maybe_set_did_classifier/3
               ,fun cdr_util:is_conference/3
               ,fun set_interaction/3
               ,fun cdr_util:filter_sensitive/3
               ,fun update_pvt_parameters/3 %% due to interaction-timestamp MUST be called LAST
               ,fun cdr_util:save_cdr/3
               ],
    _ = lists:foldl(fun(F, J) -> F(AccountId, Timestamp, J) end
                   ,JObj
                   ,Routines
                   ),
    'ok'.

-spec update_pvt_parameters(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
update_pvt_parameters('undefined', _, JObj) ->
    Props = [{'type', 'cdr'}
            ,{'crossbar_doc_vsn', 2}
            ],
    kz_doc:update_pvt_parameters(JObj, ?KZ_ANONYMOUS_CDR_DB, Props);
update_pvt_parameters(AccountId, Timestamp, JObj) ->
    CorrectTimestamp = kz_json:get_integer_value(<<"Interaction-Time">>, JObj, Timestamp),
    AccountMODb = kzs_util:format_account_id(AccountId, CorrectTimestamp),
    Props = [{'type', 'cdr'}
            ,{'crossbar_doc_vsn', 2}
            ,{'account_id', AccountId}
            ],
    kz_doc:update_pvt_parameters(JObj, AccountMODb, Props).

-spec set_interaction(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
set_interaction(_AccountId, _Timestamp, JObj) ->
    %% See {@link prepare_and_save/3} for an edge case for Timestamp
    InteractionKey = <<?CALL_INTERACTION_ID>>,
    InteractionIsRootKey = <<?CALL_INTERACTION, "-Is-Root">>,
    Interaction = kz_call_event:custom_channel_var(JObj, InteractionKey, ?CALL_INTERACTION_DEFAULT),
    InteractionIsRoot = kz_call_event:custom_channel_var(JObj, InteractionIsRootKey, 'false'),
    <<Time:11/binary, "-", Key/binary>> = Interaction,
    Timestamp = kz_term:to_integer(Time),
    DeleteKeys = [cdr_util:ccv_path(InteractionKey)
                 ,cdr_util:ccv_path(InteractionIsRootKey)
                 ],
    Values = [{<<"Interaction-Time">>, Timestamp}
             ,{<<"Interaction-Key">>, Key}
             ,{<<"Interaction-Id">>, Interaction}
             ,{<<"Interaction-Is-Root">>, InteractionIsRoot}
             ],
    Routines = [fun(J) -> kz_json:delete_keys(DeleteKeys, J) end
               ,fun(J) -> kz_json:set_values(Values, J) end
               ],
    lists:foldl(fun(F, Acc) -> F(Acc) end, JObj, Routines).
