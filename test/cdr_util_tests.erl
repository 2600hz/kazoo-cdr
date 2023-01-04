%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cdr_util_tests).

-include_lib("eunit/include/eunit.hrl").

get_cdr_doc_id_test_() ->
    Test = fun cdr_util:get_cdr_doc_id/2,
    Test1 = fun cdr_util:get_cdr_doc_id/3,
    CallId = kz_binary:rand_hex(16),
    {Year, Month, _} = erlang:date(),
    Expected = <<(kz_term:to_binary(Year))/binary, (kz_date:pad_month(Month))/binary, "-", CallId/binary>>,

    [{"Timestamp provided"
     ,?_assertEqual(Expected, Test(kz_time:now_s(), CallId))
     }
    ,{"Year, Month, and CallId provided"
     ,?_assertEqual(Expected, Test1(Year, Month, CallId))
     }
    ].
