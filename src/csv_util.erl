%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
%%% @doc Utility module for V3 Kazoo Migration
%%% @author Ben Wann
%%% @author James Aimonetti
%%% @author Karl Anderson
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(csv_util).

-include("cdr.hrl").

%% API
-export([json_objs_to_csv/1
        ,test_convert/1
        ]).

-define(INCLUDE_HEADERS, 'true').

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc TODO: change name...
%% @end
%%------------------------------------------------------------------------------
-spec json_objs_to_csv(kz_json:objects()) -> iolist().
json_objs_to_csv([]) -> [];
json_objs_to_csv(JObjs) ->
    kz_json:encode(JObjs).

-spec test_convert(kz_term:ne_binary()) -> 'ok' | {'error', any()}.
test_convert(AccountDb) ->
    ViewOptions = ['include_docs'],
    case kz_datamgr:get_results(AccountDb, <<"cdrs/crossbar_listing">>, ViewOptions) of
        {'ok', []} -> 'ok';
        {'error', _E} ->
            lager:error("failed view ~s: ~p", [AccountDb, _E]), [];
        {'ok', JObjs} ->
            test_convert_cdrs(JObjs)
    end.

test_convert_cdrs(JObjs) ->
    CdrDocs = lists:foldr(fun test_convert_cdr/2, [], JObjs),
    CsvData = json_objs_to_csv(CdrDocs),
    maybe_save_csv("test.csv", CsvData).

test_convert_cdr(JObj, Acc) ->
    Doc = kz_json:get_json_value([<<"doc">>], JObj),
    [kz_json:delete_key(<<"custom_channel_vars">>, Doc) | Acc].

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec maybe_save_csv(file:name(), iolist()) -> 'ok' | {'error', any()}.
maybe_save_csv(FileName, CsvData) ->
    TestPath = filename:join(code:priv_dir('cdr'), "test_data"),
    case filelib:ensure_dir(TestPath) of
        'ok' ->
            FilePath = filename:join(TestPath, FileName),
            kz_os:write_file(FilePath, CsvData);
        {'error', _}=Error ->
            lager:error("error creating directory: ~p", [Error]),
            Error
    end.
