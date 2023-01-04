%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
%%% @doc Listen for CDR events and record them to the database
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cdr_report).

-export([handle_req/2]).

-include("cdr.hrl").

-define(IGNORED_APP, kapps_config:get(?CONFIG_CAT, <<"ignore_apps">>, [<<"milliwatt">>])).

-define(REORDER_KEY, <<"ignore_reorder_reasons">>).
-define(IGNORED_REORDER(AccountId),
        case AccountId of
            'undefined' -> kapps_config:get_ne_binaries(?CONFIG_CAT, ?REORDER_KEY, []);
            _ -> kapps_account_config:get_global(AccountId, ?CONFIG_CAT, ?REORDER_KEY, [])
        end).

-define(LOOPBACK_KEY, <<"ignore_loopback_bowout">>).
-define(IGNORE_LOOPBACK(AccountId),
        case AccountId of
            'undefined' -> kapps_config:get_is_true(?CONFIG_CAT, ?LOOPBACK_KEY, 'true');
            _ -> kapps_account_config:get_global(AccountId, ?CONFIG_CAT, ?LOOPBACK_KEY, 'true')
        end).

-spec handle_req(kz_call_event:payload(), kz_term:proplist()) -> 'ok'.
handle_req(JObj, _Props) ->
    'true' = kapi_cdr:report_v(JObj),
    _ = kz_log:put_callid(JObj),
    Routines = [fun maybe_ignore_app/1
               ,fun maybe_ignore_loopback/1
               ,fun maybe_ignore_reorder/1
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
     andalso kz_json:is_true(<<"Channel-Loopback-Bowout-Used">>, JObj)
    ,<<"ignoring cdr request for loopback channel">>
    }.

-spec maybe_ignore_reorder(kz_call_event:payload()) -> {boolean(), binary()}.
maybe_ignore_reorder(JObj) ->
    Reason = kz_call_event:custom_channel_var(JObj, <<"Reorder-Reason">>, <<"no_reason">>),
    AppName = kz_call_event:custom_channel_var(JObj, <<"Application-Name">>),
    {(AppName =:= <<"reorder">>)
     andalso lists:member(Reason, ?IGNORED_REORDER(kz_call_event:account_id(JObj)))
    ,<<"ignoring reorder cdr for ", Reason/binary>>
    }.

-spec handle_req(kz_call_event:payload()) -> 'ok'.
handle_req(JObj) ->
    AccountId = kapi_cdr:account_id(JObj),
    Timestamp = kapi_cdr:timestamp(JObj),
    prepare_and_save(AccountId, Timestamp, JObj).

-spec prepare_and_save(account_id(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> 'ok'.
prepare_and_save(AccountId, Timestamp, JObj) ->
    Routines = [fun cdr_util:update_ccvs/3
               ,fun cdr_util:set_doc_id/3
               ,fun cdr_util:set_recording_url/3
               ,fun cdr_util:set_call_priority/3
               ,fun cdr_util:maybe_set_e164_destination/3
               ,fun cdr_util:maybe_set_e164_origination/3
               ,fun cdr_util:maybe_set_did_classifier/3
               ,fun cdr_util:is_conference/3
               ,fun check_attendend_transfer/3
               ,fun check_attendend_transfer_loopback/3
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
            ,{'crossbar_doc_vsn', 3}
            ],
    kz_doc:update_pvt_parameters(JObj, ?KZ_ANONYMOUS_CDR_DB, Props);
update_pvt_parameters(AccountId, Timestamp, JObj) ->
    AccountMODb = kzs_util:format_account_id(AccountId, Timestamp),
    Props = [{'type', 'cdr'}
            ,{'crossbar_doc_vsn', 3}
            ,{'account_id', AccountId}
            ],
    kz_doc:update_pvt_parameters(JObj, AccountMODb, Props).

-spec set_interaction(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
set_interaction(_AccountId, _Timestamp, JObj) ->
    kz_json:set_values([{<<"Interaction-Time">>, kapi_cdr:interaction_timestamp(JObj)}
                       ,{<<"Interaction-Key">>, kapi_cdr:interaction_key(JObj)}
                       ,{<<"Interaction-Id">>, kapi_cdr:interaction_id(JObj)}
                       ,{<<"Interaction-Is-Root">>, kapi_cdr:interaction_is_root(JObj)}
                       ,{cdr_util:ccv_path(<<?CALL_INTERACTION_ID>>), 'null'}
                       ,{cdr_util:ccv_path(<<?CALL_INTERACTION, "-Is-Root">>), 'null'}
                       ,{<<"Call-Interaction">>, 'null'}
                       ]
                      ,JObj
                      ).

-spec check_attendend_transfer(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
check_attendend_transfer(AccountId, Timestamp, JObj) ->
    case kz_call_event:endpoint_disposition(JObj) of
        <<"ATTENDED_TRANSFER">> ->
            kz_process:spawn(fun fix_att_xfer_interaction_id/3, [AccountId, Timestamp, JObj]),
            JObj;
        _Other ->
            JObj
    end.

-spec check_attendend_transfer_loopback(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
check_attendend_transfer_loopback(AccountId, Timestamp, JObj) ->
    case is_loopback_leg_payload(JObj, <<"A">>) of
        'true' ->
            Props = att_xfer_update_props(JObj),
            LoopbackBLeg = kz_json:get_ne_binary_value(<<"Channel-Loopback-Other-Leg-ID">>, JObj),
            kz_process:spawn(fun fix_att_xfer_id_loopback_delayed/4, [AccountId, Timestamp, Props, LoopbackBLeg]),
            JObj;
        _Other ->
            JObj
    end.

-spec originated_uuids_payload(kz_call_event:payload()) -> kz_term:ne_binaries().
originated_uuids_payload(JObj) ->
    [CallId
     || J <- kz_json:get_list_value(<<"Originated-Legs">>, JObj, []),
        CallId <- [kz_json:get_ne_binary_value(<<"Call-ID">>, J)],
        CallId =/= 'undefined'
    ].

-spec originated_uuids(kz_call_event:payload()) -> kz_term:ne_binaries().
originated_uuids(JObj) ->
    [CallId
     || J <- kz_json:get_list_value(<<"originated_legs">>, JObj, []),
        CallId <- [kz_json:get_ne_binary_value(<<"call_id">>, J)],
        CallId =/= 'undefined'
    ].

att_xfer_update_props(JObj) ->
    [{<<"interaction_time">>, kapi_cdr:interaction_timestamp(JObj)}
    ,{<<"interaction_key">>, kapi_cdr:interaction_key(JObj)}
    ,{<<"interaction_id">>, kapi_cdr:interaction_id(JObj)}
    ,{<<"interaction_is_root">>, null}
    ].

fix_att_xfer_interaction_id(AccountId, Timestamp, JObj) ->
    Props = att_xfer_update_props(JObj),
    Legs = originated_uuids_payload(JObj),
    lager:info_unsafe("legs => ~s", [kz_binary:join(Legs)]),
    timer:sleep(?MILLISECONDS_IN_SECOND * 10),
    fix_att_xfer_interaction_id(AccountId, Timestamp, Legs, Props).

fix_att_xfer_interaction_id(_AccountId, _Timestamp, [], _Props) -> 'ok';
fix_att_xfer_interaction_id(AccountId, Timestamp, [LegId | Legs], Props) ->
    DB = kzs_util:format_account_id(AccountId, Timestamp),
    Id = cdr_util:get_cdr_doc_id(Timestamp, LegId),
    Result = kz_datamgr:update_doc(DB, Id, [{'update', Props}, {'should_create', 'false'}]),
    maybe_fix_att_xfer_id_loopback(AccountId, Timestamp, Props, Result),
    fix_att_xfer_interaction_id(AccountId, Timestamp, Legs, Props).

maybe_fix_att_xfer_id_loopback(AccountId, Timestamp, Props, {ok, Updated}) ->
    case is_loopback_leg(Updated, <<"A">>) of
        true ->
            LoopbackBLeg = kz_json:get_ne_binary_value(<<"channel_loopback_other_leg_id">>, Updated),
            fix_att_xfer_id_loopback(AccountId, Timestamp, Props, LoopbackBLeg);
        false -> ok
    end;
maybe_fix_att_xfer_id_loopback(_AccountId, _Timestamp, _Props, _Other) -> ok.

fix_att_xfer_id_loopback(_AccountId, _Timestamp, _Props, undefined) ->
    lager:warning("cdr of loopback A channel misses B leg");
fix_att_xfer_id_loopback(AccountId, Timestamp, Props, LoopbackBLeg) ->
    DB = kzs_util:format_account_id(AccountId, Timestamp),
    Id = cdr_util:get_cdr_doc_id(Timestamp, LoopbackBLeg),
    case kz_datamgr:update_doc(DB, Id, [{'update', Props}, {'should_create', 'false'}]) of
        {ok, JObj} -> fix_att_xfer_interaction_id(AccountId, Timestamp, originated_uuids(JObj), Props);
        _Other -> ok
    end.

fix_att_xfer_id_loopback_delayed(AccountId, Timestamp, Props, LoopbackBLeg) ->
    timer:sleep(?MILLISECONDS_IN_SECOND * 10),
    fix_att_xfer_id_loopback(AccountId, Timestamp, Props, LoopbackBLeg).

is_loopback_leg(JObj, Leg) ->
    kz_json:is_true(<<"channel_is_loopback">>, JObj)
        andalso kz_json:is_true(<<"channel_loopback_bowout">>, JObj)
        andalso kz_json:get_ne_binary_value(<<"channel_loopback_leg">>, JObj) =:= Leg.

is_loopback_leg_payload(JObj, Leg) ->
    kz_json:is_true(<<"Channel-Is-Loopback">>, JObj)
        andalso kz_json:is_true(<<"Channel-Loopback-Bowout">>, JObj)
        andalso kz_json:get_ne_binary_value(<<"Channel-Loopback-Leg">>, JObj) =:= Leg.
