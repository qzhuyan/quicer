%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(quicer_app).

-behaviour(application).

-export([ start/2
        , stop/1
        ]).

%% Export for manual ops
-export([listeners_stop_all/0]).

start(_StartType, _StartArgs) ->
    quicer:open_lib(),
    Profile = application:get_env(quicer, profile, quic_execution_profile_low_latency),
    quicer:reg_open(Profile),
    quicer_sup:start_link().

stop(_) ->
    %% close all listeners before shutdown and
    %% close the global Registration
    listeners_stop_all(),
    quicer:reg_close(),
    quicer:close_lib(),
    ok.

listeners_stop_all() ->
    lists:foreach(
      fun({ {Name, _Port}, _}) ->
              quicer:stop_listener(Name)
      end, quicer:listeners()).
