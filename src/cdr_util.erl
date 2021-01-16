%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2021, 2600Hz
%%% @doc Utility module for CDR operations
%%% @author Ben Wann
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cdr_util).

-export([get_cdr_doc_id/2
        ,get_cdr_doc_id/3

        ,register_views/0
        ]).

-export([prepare_save_channel_destroy/3]).
-export([prepare_save_report/3]).
-export([save_cdr/2]).

-include("cdr.hrl").

-define(CHANNEL_VARS, <<"Custom-Channel-Vars">>).
-define(CCV(Key), [?CHANNEL_VARS, Key]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec get_cdr_doc_id(kz_time:gregorian_seconds(), kz_term:api_binary()) ->
          kz_term:ne_binary().
get_cdr_doc_id(Timestamp, CallId) ->
    kzd_cdrs:create_doc_id(CallId, Timestamp).

-spec get_cdr_doc_id(pos_integer(), pos_integer(), kz_term:api_binary()) -> kz_term:ne_binary().
get_cdr_doc_id(Year, Month, CallId) ->
    kzd_cdrs:create_doc_id(CallId, Year, Month).

-spec get_correct_cdr_doc_id(kz_term:ne_binary(), kz_json:object(), kz_term:api_gregorian_seconds()) -> kz_term:api_ne_binary().
get_correct_cdr_doc_id(CallId, JObj, 'undefined') ->
    get_correct_cdr_doc_id(CallId, JObj, kz_time:now_s());
get_correct_cdr_doc_id(CallId, JObj, Timestamp) ->
    %% See the note about midnight of the last day of the month edge case
    %% in `update_pvt_parameters/3'.
    CorrectTimestamp = kz_json:get_integer_value(<<"Interaction-Time">>
                                                ,JObj
                                                ,kz_json:get_integer_value(<<"interaction_time">>, JObj, Timestamp)
                                                ),
    get_cdr_doc_id(CorrectTimestamp, CallId).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec save_cdr(kz_term:api_binary(), kz_json:object()) -> 'ok' | {'error', 'max_save_retries'}.
save_cdr(?KZ_ANONYMOUS_CDR_DB=Db, Doc) ->
    case kapps_config:get_is_true(?CONFIG_CAT, <<"store_anonymous">>, 'false') of
        'false' -> lager:debug("ignoring storage for anonymous cdr");
        'true' -> do_save_cdr(Db, Doc)
    end;
save_cdr(AccountMOD, Doc) ->
    do_save_cdr(AccountMOD, Doc).

-spec do_save_cdr(kz_term:api_binary(), kz_json:object()) -> 'ok' | {'error', 'max_save_retries'}.
do_save_cdr(AccountMODb, Doc) ->
    case kazoo_modb:save_doc(AccountMODb, Doc, [{'max_retries', 3}]) of
        {'ok', _}-> 'ok';
        {'error', 'conflict'} -> 'ok';
        {'error', _E} ->
            lager:debug("failed to save cdr ~s : ~p", [kz_doc:id(Doc), _E]),
            {'error', 'max_save_retries'}
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec register_views() -> 'ok'.
register_views() ->
    kz_datamgr:register_views_from_folder('cdr').


%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec prepare_save_channel_destroy(account_id(), kz_time:api_gregorian_seconds(), kz_call_event:payload()) -> kz_json:object().
prepare_save_channel_destroy(AccountId, 'undefined', JObj) ->
    lager:info("failed to find timestamp on CHANNEL_DESTROY"),
    prepare_save_channel_destroy(AccountId, kz_time:now_s(), JObj);
prepare_save_channel_destroy(AccountId, Timestamp, JObj) ->
    Routines = [fun prepare_save/3
               ,fun set_channel_destroy_interaction/3
               ,fun pvt_parameters_vsn_2/3
               ,fun set_doc_id/3
               ],
    lists:foldl(fun(F, J) -> F(AccountId, Timestamp, J) end
               ,JObj
               ,Routines
               ).

-spec set_channel_destroy_interaction(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
set_channel_destroy_interaction(_AccountId, _Timestamp, JObj) ->
    InteractionKey = <<?CALL_INTERACTION_ID>>,
    InteractionIsRootKey = <<?CALL_INTERACTION, "-Is-Root">>,
    Interaction = kz_call_event:custom_channel_var(JObj, InteractionKey, ?CALL_INTERACTION_DEFAULT),
    InteractionIsRoot = kz_call_event:custom_channel_var(JObj, InteractionIsRootKey, false),
    <<Time:11/binary, "-", Key/binary>> = Interaction,
    Timestamp = kz_term:to_integer(Time),
    DeleteKeys = [?CCV(InteractionKey)
                 ,?CCV(InteractionIsRootKey)
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

-spec pvt_parameters_vsn_2(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
pvt_parameters_vsn_2(AccountId, Timestamp, JObj) ->
    update_pvt_parameters(AccountId, Timestamp, JObj, 2).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec prepare_save_report(account_id(), kz_time:api_gregorian_seconds(), kz_call_event:payload()) -> kz_json:object().
prepare_save_report(AccountId, 'undefined', JObj) ->
    lager:info("failed to find timestamp on CDR_REPORT"),
    prepare_save_report(AccountId, kz_time:now_s(), JObj);
prepare_save_report(AccountId, Timestamp, JObj) ->
    Routines = [fun prepare_save/3
               ,fun set_report_interaction/3
               ,fun pvt_parameters_vsn_2/3
               ,fun pvt_parameters_vsn_3/3
               ,fun set_doc_id/3
               ,fun check_attendend_transfer/3
               ,fun check_attendend_transfer_loopback/3
               ],
    lists:foldl(fun(F, J) -> F(AccountId, Timestamp, J) end
               ,JObj
               ,Routines
               ).

-spec set_report_interaction(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
set_report_interaction(_AccountId, _Timestamp, JObj) ->
    kz_json:set_values([{<<"Interaction-Time">>, kapi_cdr:interaction_timestamp(JObj)}
                       ,{<<"Interaction-Key">>, kapi_cdr:interaction_key(JObj)}
                       ,{<<"Interaction-Id">>, kapi_cdr:interaction_id(JObj)}
                       ,{<<"Interaction-Is-Root">>, kapi_cdr:interaction_is_root(JObj)}
                       ,{?CCV(<<?CALL_INTERACTION_ID>>), null}
                       ,{?CCV(<<?CALL_INTERACTION, "-Is-Root">>), null}
                       ,{<<"Call-Interaction">>, null}
                       ]
                      ,JObj
                      ).

-spec pvt_parameters_vsn_3(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
pvt_parameters_vsn_3(AccountId, Timestamp, JObj) ->
    update_pvt_parameters(AccountId, Timestamp, JObj, 3).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec prepare_save(account_id(), kz_time:api_gregorian_seconds(), kz_call_event:payload()) -> kz_json:object().
prepare_save(AccountId, 'undefined', JObj) ->
    lager:info("failed to find timestamp on CDR"),
    lager:debug("event: ~p", [JObj]),
    prepare_save(AccountId, kz_time:now_s(), JObj);
prepare_save(AccountId, Timestamp, JObj) ->
    Routines = [fun update_ccvs/3
               ,fun set_recording_url/3
               ,fun set_call_priority/3
               ,fun maybe_set_e164_destination/3
               ,fun maybe_set_e164_origination/3
               ,fun maybe_set_did_classifier/3
               ,fun is_conference/3
               ],
    lists:foldl(fun(F, J) -> F(AccountId, Timestamp, J) end
               ,JObj
               ,Routines
               ).

-spec update_pvt_parameters(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload(), non_neg_integer()) ->
          kz_call_event:payload().
update_pvt_parameters('undefined', _, JObj, Vsn) ->
    Props = [{'type', 'cdr'}
            ,{'crossbar_doc_vsn', Vsn}
            ],
    kz_doc:update_pvt_parameters(JObj, ?KZ_ANONYMOUS_CDR_DB, Props);
update_pvt_parameters(AccountId, Timestamp, JObj, Vsn) ->
    %% CAUTION: The Timestamp is possibly ahead of interaction-timestamp.
    %% To setting the correct doc ID and save the CDR in the same MODB where the CDR of initial channel was saved,
    %% it is important that we use interaction-timestamp. The edge case here is at the midnight of the last day of the
    %% month. The call was start sometime before midnight, but ended after midnight in the first day of the next month,
    %% so we MUST use the interaction-timestamp to find the correct MODB to save all the legs of the call in the same
    %% MODB. This also avoids breaking of cb_cdrs and interaction view because of this edge case.
    CorrectTimestamp = kz_json:get_integer_value(<<"Interaction-Time">>, JObj, Timestamp),
    AccountMODb = kzs_util:format_account_id(AccountId, CorrectTimestamp),
    Props = [{'type', 'cdr'}
            ,{'crossbar_doc_vsn', Vsn}
            ,{'account_id', AccountId}
            ],
    kz_doc:update_pvt_parameters(JObj, AccountMODb, Props).

-spec set_doc_id(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
set_doc_id(_AccountId, Timestamp, JObj) ->
    %% we should consider adding kz_binary:rand_hex(16) as ReportId
    %% as there may exist the same CallId in different servers
    %% like in the case of nightmare transfers or conference bridges
    %% Or because there is a lost channel in case of nightmare transfers.
    %% CallId = kz_binary:rand_hex(16),
    CallId = kz_call_event:call_id(JObj),
    kz_doc:set_id(JObj, get_correct_cdr_doc_id(CallId, JObj, Timestamp)).

-spec update_ccvs(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
update_ccvs(_, _, JObj) ->
    CCVs = kz_call_event:custom_channel_vars(JObj, kz_json:new()),
    {UpdatedJObj, UpdatedCCVs} =
        kz_json:foldl(fun update_ccvs_foldl/3
                     ,{JObj, CCVs}
                     ,CCVs
                     ),
    kz_json:set_value(?CHANNEL_VARS, UpdatedCCVs, UpdatedJObj).

-spec update_ccvs_foldl(kz_json:get_key(), kz_json:json_term(), {kz_call_event:payload(), kz_json:object()}) ->
          {kz_call_event:payload(), kz_json:object()}.
update_ccvs_foldl(Key, Value, {JObj, CCVs}=Acc) ->
    case kz_doc:is_private_key(Key) of
        'false' -> Acc;
        'true' ->
            {kz_json:set_value(Key, Value, JObj)
            ,kz_json:delete_key(Key, CCVs)
            }
    end.

-spec set_call_priority(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
set_call_priority(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"Call-Priority">>).

-spec set_recording_url(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
set_recording_url(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"Recording-Url">>).

-spec maybe_set_e164_destination(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
maybe_set_e164_destination(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"E164-Destination">>).

-spec maybe_set_e164_origination(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
maybe_set_e164_origination(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"E164-Origination">>).

-spec maybe_set_did_classifier(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
maybe_set_did_classifier(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"DID-Classifier">>).

-spec is_conference(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
is_conference(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"Is-Conference">>, {fun kz_json:is_true/3, 'false'}).

-spec maybe_leak_ccv(kz_call_event:payload(), kz_json:get_key()) -> kz_call_event:payload().
maybe_leak_ccv(JObj, Key) ->
    maybe_leak_ccv(JObj, Key, {fun kz_json:get_value/3, 'undefined'}).

-spec maybe_leak_ccv(kz_call_event:payload(), kz_json:get_key(), {fun(), any()}) -> kz_call_event:payload().
maybe_leak_ccv(JObj, Key, {GetFun, Default}) ->
    case GetFun(?CCV(Key), JObj, Default) of
        'undefined' -> JObj;
        Default -> JObj;
        Value -> kz_json:set_value(Key
                                  ,Value
                                  ,kz_json:delete_key(?CCV(Key), JObj)
                                  )
    end.


%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
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
            kz_process:spawn(fun fix_att_xfer_id_loopback_delayed/5, [AccountId, Timestamp, Props, LoopbackBLeg, JObj]),
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

-spec att_xfer_update_props(kz_call_event:payload()) -> kz_term:proplist().
att_xfer_update_props(JObj) ->
    [{<<"interaction_time">>, kapi_cdr:interaction_timestamp(JObj)}
    ,{<<"interaction_key">>, kapi_cdr:interaction_key(JObj)}
    ,{<<"interaction_id">>, kapi_cdr:interaction_id(JObj)}
    ,{<<"interaction_is_root">>, 'null'}
    ].

-spec fix_att_xfer_interaction_id(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> 'ok'.
fix_att_xfer_interaction_id(AccountId, Timestamp, JObj) ->
    Props = att_xfer_update_props(JObj),
    Legs = originated_uuids_payload(JObj),
    lager:info_unsafe("legs => ~p", [Legs]),
    timer:sleep(?MILLISECONDS_IN_SECOND * 10),
    fix_att_xfer_interaction_id(AccountId, Timestamp, Legs, Props, JObj).

-spec fix_att_xfer_interaction_id(kz_term:api_ne_binary(), kz_time:gregorian_seconds()
                                 ,kz_term:ne_binaries(), kz_term:proplist()
                                 ,kz_call_event:payload()
                                 ) -> 'ok'.
fix_att_xfer_interaction_id(_AccountId, _Timestamp, [], _Props, _JObj) ->
    'ok';
fix_att_xfer_interaction_id(AccountId, Timestamp, [LegId | Legs], Props, JObj) ->
    DB = kzs_util:format_account_id(AccountId, Timestamp),
    Id = get_correct_cdr_doc_id(LegId, JObj, Timestamp),
    Result = kz_datamgr:update_doc(DB, Id, [{'update', Props}, {'should_create', 'false'}]),
    maybe_fix_att_xfer_id_loopback(AccountId, Timestamp, Props, Result, JObj),
    fix_att_xfer_interaction_id(AccountId, Timestamp, Legs, Props, JObj).

-spec maybe_fix_att_xfer_id_loopback(kz_term:api_ne_binary(), kz_time:gregorian_seconds()
                                    ,kz_term:proplist(), {'ok', kz_json:object()} | kazoo_data:data_error()
                                    ,kz_call_event:payload()
                                    ) -> 'ok'.
maybe_fix_att_xfer_id_loopback(AccountId, Timestamp, Props, {'ok', Updated}, JObj) ->
    case is_loopback_leg(Updated, <<"A">>) of
        'true' ->
            LoopbackBLeg = kz_json:get_ne_binary_value(<<"channel_loopback_other_leg_id">>, Updated),
            fix_att_xfer_id_loopback(AccountId, Timestamp, Props, LoopbackBLeg, JObj);
        'false' -> 'ok'
    end;
maybe_fix_att_xfer_id_loopback(_AccountId, _Timestamp, _Props, _Other, _JObj) ->
    'ok'.

-spec fix_att_xfer_id_loopback(kz_term:api_ne_binary(), kz_time:gregorian_seconds()
                              ,kz_term:proplist(), kz_term:api_ne_binary()
                              ,kz_call_event:payload()
                              ) -> 'ok'.
fix_att_xfer_id_loopback(_AccountId, _Timestamp, _Props, 'undefined', _JObj) ->
    lager:warning("cdr of loopback A channel misses B leg");
fix_att_xfer_id_loopback(AccountId, Timestamp, Props, LoopbackBLeg, JObj) ->
    DB = kzs_util:format_account_id(AccountId, Timestamp),
    Id = get_correct_cdr_doc_id(LoopbackBLeg, JObj, Timestamp),
    case kz_datamgr:update_doc(DB, Id, [{'update', Props}, {'should_create', 'false'}]) of
        {'ok', JObj} -> fix_att_xfer_interaction_id(AccountId, Timestamp, originated_uuids(JObj), Props, JObj);
        _Other -> 'ok'
    end.

-spec fix_att_xfer_id_loopback_delayed(kz_term:api_ne_binary(), kz_time:gregorian_seconds()
                                      ,kz_term:proplist(), kz_term:api_ne_binary()
                                      ,kz_call_event:payload()
                                      ) -> 'ok'.
fix_att_xfer_id_loopback_delayed(AccountId, Timestamp, Props, LoopbackBLeg, JObj) ->
    timer:sleep(?MILLISECONDS_IN_SECOND * 10),
    fix_att_xfer_id_loopback(AccountId, Timestamp, Props, LoopbackBLeg, JObj).

-spec is_loopback_leg(kz_json:object(), kz_term:ne_binary()) -> boolean().
is_loopback_leg(JObj, Leg) ->
    kz_json:is_true(<<"channel_is_loopback">>, JObj)
        andalso kz_json:is_true(<<"channel_loopback_bowout">>, JObj)
        andalso kz_json:get_ne_binary_value(<<"channel_loopback_leg">>, JObj) =:= Leg.

-spec is_loopback_leg_payload(kz_call_event:payload(), kz_term:ne_binary()) -> boolean().
is_loopback_leg_payload(JObj, Leg) ->
    kz_json:is_true(<<"Channel-Is-Loopback">>, JObj)
        andalso kz_json:is_true(<<"Channel-Loopback-Bowout">>, JObj)
        andalso kz_json:get_ne_binary_value(<<"Channel-Loopback-Leg">>, JObj) =:= Leg.
