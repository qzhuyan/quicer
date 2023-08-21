%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(quicer_hotupgrade_SUITE).
-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(BASETAG, "0.0.114").

all() ->
    [{group, without_traffic}].

groups() ->
    [{without_traffic, [], [ tc_app_unload
                           , tc_app_restart
                           , tc_application_reload_fail
                           , tc_quicer_nif_reload
                           , tc_quicer_nif_soft_purge
                           , tc_quicer_nif_soft_purge_withold
                           , tc_quicer_nif_purge
                           , tc_quicer_nif_reload_unload_old
                           , tc_quicer_nif_delete
                           , tc_patching_with_paths
                           ]}].

init_per_suite(Config) ->
    TAG = ?BASETAG,
    DDir = ?config(data_dir, Config),
    ct:pal("~p~n", [os:cmd(io_lib:format("bash ~s/build_base.sh ~s", [DDir, TAG]))]),
    BaseAppPath = lists:flatten(io_lib:format("~s/quic-~s/_build/default/lib/quicer/", [DDir, TAG])),
    application:stop(quicer),
    application:start(quicer),
    quicer:reg_open(),
    [{base_app_dir, BaseAppPath} | Config].

end_per_suite(_Config) ->
    ok.

init_per_group(without_traffic, Config) ->
    Config.

end_per_group(without_traffic, Config) ->
    Config.

init_per_testcase(_, Config) ->
    ct:pal("~p~n: mapped quicer shared libs: ~p", [?FUNCTION_NAME, quicer:nif_mapped()]),
    reset(Config),
    %% @NOTE, When run with ASAN, the RO data of shared lib is still mapped.
    ct:pal("~p~n: After RESET: mapped quicer shared libs: ~p", [?FUNCTION_NAME, quicer:nif_mapped()]),
    Config.

end_per_testcase(_, Config) ->
    ct:pal("~p~n: mapped quicer shared libs: ~p", [?FUNCTION_NAME, quicer:nif_mapped()]),
    Config.

tc_app_restart(_) ->
    application:ensure_all_started(quicer),
    ok = application:stop(quicer),
    ok = application:start(quicer),
    ok.

tc_app_unload(_)->
    application:ensure_all_started(quicer),
    application:stop(quicer),
    ok = application:unload(quicer).


tc_quicer_nif_reload(_) ->
    application:ensure_all_started(quicer),
    ?assertEqual({module, quicer_nif}, code:load_file(quicer_nif)).


tc_quicer_nif_soft_purge(_) ->
    application:ensure_all_started(quicer),
    %% When no old code
    ?assert(code:soft_purge(quicer_nif)),
    %% Then soft purge succcess
    ?assert(erlang:module_loaded(quicer_nif)).

tc_quicer_nif_soft_purge_withold(_Config) ->
    %% Given loaded quicer_nif
    application:ensure_all_started(quicer),
    %% When base nif module is reloaded successfully
    ?assertEqual({module, quicer_nif}, code:load_file(quicer_nif)),
    %% Then soft purge should success
    ?assert(code:soft_purge(quicer_nif)).

tc_quicer_nif_purge(_) ->
    application:ensure_all_started(quicer),
    false = code:purge(quicer_nif),
    ?assertEqual(true, erlang:module_loaded(quicer_nif)).

tc_quicer_nif_reload_unload_old(Config) ->
    Path = ?config(base_app_dir, Config)++"/ebin",

    %% Given quicer app is started and no old code
    application:ensure_all_started(quicer),
    %% dummy call ensure no old code
    code:purge(quicer_nif),

    ModuleInfoOld = quicer_nif:module_info(),

    %% When base nif module is reloaded successfully
    code:add_patha(Path),
    false = code:purge(quicer_nif),
    ?assertEqual({module, quicer_nif}, code:load_file(quicer_nif)),
    ct:pal("loaded old quicer_nif: ~p", [quicer_nif:module_info()]),

    %% Then quicer_nif is reloaded as base version
    ?assertNotEqual(ModuleInfoOld, quicer_nif:module_info()),

    %% When base nif module is removed from path
    code:del_path(Path),
    code:purge(quicer_nif),

    %% Then reload nif module fallback it to latest version
    ?assertEqual({module, quicer_nif}, code:load_file(quicer_nif)),
    ?assertEqual(ModuleInfoOld, quicer_nif:module_info()),
    ok.

tc_quicer_nif_delete(_Config) ->
    %% Given quicer_nif is loaded
    application:ensure_all_started(quicer),
    code:purge(quicer_nif),
    %% When delete the nif module
    ?assert(code:delete(quicer_nif)),
    %% Then the nif module is unloaded
    ?assert(not erlang:module_loaded(quicer_nif)).

tc_application_reload_fail(Config) ->
    Path = ?config(base_app_dir, Config),
    application:ensure_all_started(quicer),
    OldPriv = code:priv_dir(quicer),
    %% Give new app path is added
    true = code:add_patha(Path),
    %% When priv dir is changed
    NewPriv = code:priv_dir(quicer),
    ?assertNotEqual(OldPriv, NewPriv),
    %% Then Reload shall fail and fall back to old module
    ct:pal("reload shall fail now ... wiht priv:~p", [NewPriv]),
    ?assertEqual({module, quicer_nif}, code:load_file(quicer_nif)).

tc_patching_with_paths(Config) ->
    Path = ?config(base_app_dir, Config),
    PathL = [Path, Path++"/ebin"],
    %% Give quicer application running...
    application:ensure_all_started(quicer),
    OldPriv = code:priv_dir(quicer),
    %% When the patches (quicer_nif and priv/libquicer_nif*) are in the path.
    ok = code:add_pathsa(PathL),
    NewPriv = code:priv_dir(quicer),
    ct:pal("old priv: ~p~nnew priv~p", [OldPriv, NewPriv]),
    ?assertNotEqual(OldPriv, NewPriv),
    %% After module is deleted
    code:purge(quicer_nif),
    ?assert(code:delete(quicer_nif)),
    %% Then load shall success
    ?assertEqual({module, quicer_nif}, code:load_file(quicer_nif)),
    ?assert(erlang:module_loaded(quicer_nif)),
    %% Then delete shall fail since there is old vsn
    ?assert(not code:delete(quicer_nif)),
    %% Then delete shall success after purge
    code:purge(quicer_nif),
    ?assert(code:delete(quicer_nif)),

    code:purge(quicer_nif).

%%%===================================================================
%%% Internal functions
%%%===================================================================
reset(Config) ->
    Path = ?config(base_app_dir, Config),
    PathL = [Path, Path++"/ebin"],
    lists:foreach(fun code:del_path/1, PathL),
    application:stop(quicer),
    case erlang:module_loaded(quicer_nif) of
        true ->
            case code:delete(quicer_nif) of
                true ->
                    code:purge(quicer_nif);
                false ->
                    code:purge(quicer_nif),
                    code:delete(quicer_nif),
                    code:purge(quicer_nif)
            end;
        false ->
            skip
    end,
    false = erlang:module_loaded(quicer_nif).
