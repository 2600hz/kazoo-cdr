%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
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
-export([save_cdr/2]).

%% shared functions for prepare_and_save in cdr_report and
%% cdr_channel_destroy
-export([update_ccvs/3
        ,set_doc_id/3
        ,set_recording_url/3
        ,set_call_priority/3
        ,maybe_set_e164_destination/3
        ,maybe_set_e164_origination/3
        ,maybe_set_did_classifier/3
        ,is_conference/3
        ,save_cdr/3
        ,filter_sensitive/3

        ,ccv_path/1
        ]).

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

-spec register_views() -> 'ok'.
register_views() ->
    kz_datamgr:register_views_from_folder('cdr').

-spec update_ccvs(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
update_ccvs(_AccountId, _Timestamp, JObj) ->
    CCVs = kz_call_event:custom_channel_vars(JObj, kz_json:new()),
    {UpdatedJObj, UpdatedCCVs} =
        kz_json:foldl(fun update_ccvs_foldl/3
                     ,{JObj, CCVs}
                     ,CCVs
                     ),
    kz_json:set_value(?CHANNEL_VARS, UpdatedCCVs, UpdatedJObj).

-spec update_ccvs_foldl(kz_json:get_key(), kz_json:json_term(), {kz_call_event:payload(), kz_json:object()}) ->
          {kz_call_event:payload(), kz_json:object()}.
update_ccvs_foldl(Key, Value,  {JObj, CCVs}=Acc) ->
    case kz_doc:is_private_key(Key) of
        'false' -> Acc;
        'true' ->
            {kz_json:set_value(Key, Value, JObj)
            ,kz_json:delete_key(Key, CCVs)
            }
    end.

-spec set_doc_id(kz_term:api_ne_binary(), 'undefined' | kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
set_doc_id(AccountId, 'undefined', JObj) ->
    set_doc_id(AccountId, kz_time:now_s(), JObj);
set_doc_id(_AcctounId, Timestamp, JObj) ->
    ReportId = kapi_cdr:call_id(JObj),
    %% we should consider adding kz_binary:rand_hex(16) as ReportId
    %% as there may exist the same CallId in different servers
    %% like in the case of nightmare transfers or conference bridges
    DocId = get_cdr_doc_id(Timestamp, ReportId),
    kz_doc:set_id(JObj, DocId).

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

-spec ccv_path(kz_json:key()) -> kz_json:path().
ccv_path(Key) -> ?CCV(Key).

-spec save_cdr(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> 'ok'.
save_cdr(_AcctId, _Timestamp, JObj) ->
    CDRDb = kz_doc:account_db(JObj),
    case save_cdr(CDRDb, kz_json:normalize_jobj(JObj)) of
        {'error', 'max_save_retries'} ->
            lager:error("write failed to ~s, too many retries", [CDRDb]);
        'ok' -> 'ok'
    end.

%% @doc checks for sensitive information and removes it from the payload
-spec filter_sensitive(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
filter_sensitive(_AccountId, _Timestamp, JObj) ->
    SensitiveKeys = [[<<"Call-Debug">>, <<"variable_sip_auth_username">>]
                    ,[<<"Call-Debug">>, <<"variable_sip_auth_password">>]

                    ,[<<"Call-Debug">>, <<"variable_ecallmgr_pvt_cost">>]
                    ,[<<"Call-Debug">>, <<"variable_group_confirm_file">>]

                    ,[<<"Call-Debug">>, <<"variable_acl_token">>]
                    ,[<<"Call-Debug">>, <<"variable_sip_acl_token">>]

                     %% could contain bridge string or playback URL
                    ,[<<"Call-Debug">>, <<"variable_last_arg">>]
                    ,[<<"Call-Debug">>, <<"variable_current_application_data">>]
                    ],
    FilteredJObj = kz_json:delete_keys(SensitiveKeys, JObj),
    find_and_filter_sensitive_logs(FilteredJObj).

find_and_filter_sensitive_logs(JObj) ->
    find_and_filter_sensitive_logs(JObj, get_logs(JObj)).

find_and_filter_sensitive_logs(JObj, 'undefined') ->
    JObj;
find_and_filter_sensitive_logs(JObj, Logs) ->
    FilteredLogs = [filter_sensitive_log(LogJObj) || LogJObj <- Logs],
    set_logs(JObj, FilteredLogs).

%% @doc LogJObj = {"app_data":"...", "app_name":"...", "app_stamp":123}
filter_sensitive_log(LogJObj) ->
    filter_sensitive_log(LogJObj
                        ,kz_json:get_value(<<"app_name">>, LogJObj)
                        ,kz_json:get_value(<<"app_data">>, LogJObj)
                        ).

filter_sensitive_log(LogJObj, _Name, <<"http_cache://", _/binary>>) ->
    lager:info("filtering http_cache URL out of app ~s", [_Name]),
    kz_json:set_value(<<"app_data">>, <<"**filtered**">>, LogJObj);
filter_sensitive_log(LogJObj, _Name, _Data) ->
    LogJObj.

get_logs(JObj) ->
    kz_json:get_list_value([<<"Extended-Data">>, <<"Channel-Application-Log">>]
                          ,JObj
                          ).

set_logs(JObj, Logs) ->
    kz_json:set_value([<<"Extended-Data">>, <<"Channel-Application-Log">>]
                     ,Logs
                     ,JObj
                     ).
