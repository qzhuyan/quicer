%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(quicer).

-include("quicer.hrl").
-include("quicer_types.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").


%% Library APIs
-export([ open_lib/0
        , close_lib/0
        , reg_open/0
        , reg_open/1
        , reg_close/0
        ]
       ).

%% Traffic APIs
-export([ listen/2
        , close_listener/1
        , connect/4
        , handshake/1
        , handshake/2
        , async_handshake/1
        , accept/2
        , accept/3
        , async_accept/2
        , shutdown_connection/1
        , shutdown_connection/2
        , shutdown_connection/3
        , shutdown_connection/4
        , async_shutdown_connection/3
        , close_connection/1
        , close_connection/3
        , close_connection/4
        , async_close_connection/1
        , async_close_connection/3
        , accept_stream/2
        , accept_stream/3
        , async_accept_stream/2
        , start_stream/2
        , send/2
        , async_send/2
        , recv/2
        , send_dgram/2
        , shutdown_stream/1
        , shutdown_stream/2
        , shutdown_stream/4
        , async_shutdown_stream/3
        , async_shutdown_stream/1
        , close_stream/1
        , close_stream/2
        , close_stream/4
        , async_close_stream/1
        , sockname/1
        , getopt/2
        , getopt/3
        , setopt/3
        , get_stream_id/1
        , getstat/2
        , peername/1
        , listeners/0
        , listener/1
        , controlling_process/2
        ]).

%% Exports for test
-export([ get_conn_rid/1
        , get_stream_rid/1
        ]).

-export([ start_listener/3 %% start application over quic
        , stop_listener/1
        ]).

-type connection_opts() :: proplists:proplist() | quicer_conn_acceptor:opts().
-type listener_opts() :: proplists:proplist() | quicer_listener:listener_opts().

%% @doc Quicer library must be opened before any use.
%%
%%      This is called automatically while quicer application is started
%% @end
-spec open_lib() ->
        {ok, true}  | %% opened
        {ok, false} | %% already opened
        {ok, debug} | %% opened with lttng debug library loaded (if present)
        {error, open_failed, atom_reason()}.
open_lib() ->
  quicer_nif:open_lib().

%% @doc Close library.
%%
%%      This is reserved for upgrade support
%%
%%      <b>Danger!</b> Do not use it!
%% @end
-spec close_lib() -> ok.
close_lib() ->
  quicer_nif:close_lib().


%% @doc Registraion should be opened before calling traffic APIs.
%%
%% This is called automatically when quicer application starts with
%% app env: `profile'
%% @end
%% @see reg_open/1
%% @see reg_close/0
reg_open() ->
  Profile = application:get_env(quicer, profile, quic_execution_profile_low_latency),
  quicer_nif:reg_open(Profile).

%% @doc Registraion should be opened before calling traffic APIs.
%% Registraion creates application context, worker threads
%% shared for all the connections
%%
%% Currently only support one application.
%% @end
%% @see reg_open/1
%% @see reg_close/0
%% @TODO support more applications with different profiles
-spec reg_open(execution_profile()) -> ok | {error, badarg}.
reg_open(Profile) ->
  quicer_nif:reg_open(Profile).

%% @doc close Registraion.
%% Reserved for future upgrade, don't use it.
%% @see reg_open/1
-spec reg_close() -> ok.
reg_close() ->
  quicer_nif:reg_close().

-spec start_listener(Appname :: atom(), listen_on(),
                     {listener_opts(), connection_opts(), stream_opts()}) ->
        {ok, pid()} | {error, any()}.
start_listener(AppName, Port, Options) ->
  quicer_listener:start_listener(AppName, Port, Options).

-spec stop_listener(atom()) -> ok.
stop_listener(AppName) ->
  quicer_listener:stop_listener(AppName).

%% @doc Start listen on Port or "HOST:PORT".
%%
%% listener_handler() is used for accepting new connection.
%% notes,
%%
%% 1. Port binding is done in NIF context, thus you cannot see it from inet:i().
%%
%% 2. ListenOn can either be integer() for Port or be String for HOST:PORT
%%
%% 3. There is no address binding even HOST is specified.
%% @end
-spec listen(listen_on(), listen_opts()) ->
        {ok, listener_handler()} |
        {error, listener_open_error,  atom_reason()} |
        {error, listener_start_error, atom_reason()}.
listen(ListenOn, Opts) when is_list(Opts) ->
  listen(ListenOn, maps:from_list(Opts));
listen(ListenOn, Opts) when is_map(Opts) ->
  quicer_nif:listen(ListenOn, Opts).

%% @doc close listener with listener handler
-spec close_listener(listener_handler()) -> ok.
close_listener(Listener) ->
  quicer_nif:close_listener(Listener).

%% @doc
%% Initial New Connection (Client)
%%
%% Initial new connection to remote endpoint with connection opts specified.
%% @end
-spec connect(inet:hostname() | inet:ip_address(),
              inet:port_number(), conn_opts(), timeout()) ->
          {ok, connection_handler()} |
          {error, conn_open_error | config_error | conn_start_error} |
          {error, timeout}.
connect(Host, Port, Opts, Timeout) when is_list(Opts) ->
  connect(Host, Port, maps:from_list(Opts), Timeout);
connect(Host, Port, Opts, Timeout) when is_tuple(Host) ->
  connect(inet:ntoa(Host), Port, Opts, Timeout);
connect(Host, Port, Opts, Timeout) when is_map(Opts) ->
  NewOpts = maps:merge(default_conn_opts(), Opts),
  case quicer_nif:async_connect(Host, Port, NewOpts) of
    {ok, H} ->
      receive
        {quic, connected, Ctx} ->
          {ok, Ctx};
        {quic, transport_shutdown, _, Reason} ->
          {error, transport_down, Reason}
      after Timeout ->
          %% @TODO caller should provide the method to handle timeout
          async_shutdown_connection(H, ?QUIC_CONNECTION_SHUTDOWN_FLAG_SILENT, 0),
          {error, timeout}
      end;
    {error, _} = Err ->
      Err
  end.


%% @doc Complete TLS handshake after accepted a Connection
%%      with 5s timeout
%% @end
%% @see accept/3
%% @see handshake/2
-spec handshake(connection_handler()) -> ok | {error, any()}.
handshake(Conn) ->
  handshake(Conn, 5000).

%% @doc Complete TLS handshake after accepted a Connection
%% @see handshake/2
%% @see async_handshake/1
-spec handshake(connection_handler(), timeout()) -> ok | {error, any()}.
handshake(Conn, Timeout) ->
  case async_handshake(Conn) of
    {error, _} = E -> E;
    ok ->
      receive
        {quic, connected, C} -> {ok, C}
      after Timeout ->
          {error, timeout}
      end
  end.

%% @doc Complete TLS handshake after accepted a Connection.
%% Caller should expect to receive ```{quic, connected, connection_handler()}'''
%%
%% @see handshake/2
-spec async_handshake(connection_handler()) -> ok | {error, any()}.
async_handshake(Conn) ->
  quicer_nif:async_handshake(Conn).

%% @doc Accept new Connection (Server)
%%
%% Accept new connection from listener_handler().
%%
%% Calling process becomes the owner of the connection.
%% @end.
-spec accept(listener_handler(), acceptor_opts()) ->
        {ok, connection_handler()} | {error, any()}.
accept(LSock, Opts) ->
  accept(LSock, Opts, infinity).


%% @doc Accept new Connection (Server) with timeout
%% @see accept/2
-spec accept(listener_handler(), acceptor_opts(), timeout()) ->
        {ok, connection_handler()} |
        {error, badarg | param_error | not_enough_mem | badpid} |
        {error, timeout}.
accept(LSock, Opts, Timeout) when is_list(Opts) ->
  accept(LSock, maps:from_list(Opts), Timeout);
accept(LSock, Opts, Timeout) ->
  % non-blocking
  {ok, LSock} = quicer_nif:async_accept(LSock, Opts),
  receive
    {quic, new_conn, C} ->
      {ok, C};
    {quic, connected, C} ->
      {ok, C}
  after Timeout ->
    {error, timeout}
  end.

-spec async_accept(listener_handler(), acceptor_opts()) ->
        {ok, listener_handler()} |
        {error, badarg | param_error | not_enough_mem | badpid}.
async_accept(Listener, Opts) ->
  NewOpts = maps:merge(default_conn_opts(), Opts),
  quicer_nif:async_accept(Listener, NewOpts).

%% @doc Starts the shutdown process on a connection and block until it is finished.
%% @see shutdown_connection/4
-spec shutdown_connection(connection_handler()) -> ok | {error, timeout | closed}.
shutdown_connection(Conn) ->
  shutdown_connection(Conn, 5000).

%% @doc Starts the shutdown process on a connection and block until it is finished.
%% but with a timeout
%% @end
%% @see shutdown_connection/4
-spec shutdown_connection(connection_handler(), timeout()) ->
        ok | {error, timeout | badarg}.
shutdown_connection(Conn, Timeout) ->
  shutdown_connection(Conn, ?QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0, Timeout).

%% @doc Starts the shutdown process on a connection with shutdown flag
%% and applications error with 5s timeout
-spec shutdown_connection(connection_handler(),
                       conn_shutdown_flag(),
                       app_errno()
                      ) -> ok | {error, timeout | badarg}.
shutdown_connection(Conn, Flags, ErrorCode) ->
  shutdown_connection(Conn, Flags, ErrorCode, 5000).

%% @doc Starts the shutdown process on a connection with shutdown flag
%% and applications error with timeout
%% @end
%% @see shutdown_connection/1
%% @see shutdown_connection/2
%% @see shutdown_connection/3
-spec shutdown_connection(connection_handler(),
                       conn_shutdown_flag(),
                       app_errno(),
                       timeout()) -> ok | {error, timeout | badarg}.
shutdown_connection(Conn, Flags, ErrorCode, Timeout) ->
  %% @todo make_ref
  case async_shutdown_connection(Conn, Flags, ErrorCode) of
    ok ->
      receive
        {quic, closed, Conn} ->
          ok
      after Timeout ->
          {error, timeout}
      end;
    {error, _} = Err ->
      Err
  end.

%% @doc Async starts the shutdown process and caller should expect for
%% connection down message {quic, close, Conn}
%% @end
-spec async_shutdown_connection(connection_handler(),
                                conn_shutdown_flag(),
                                app_errno()) -> ok | {error, badarg | closed}.
async_shutdown_connection(Conn, Flags, ErrorCode) ->
  quicer_nif:async_shutdown_connection(Conn, Flags, ErrorCode).

-spec close_connection(connection_handler()) -> ok | {error, badarg}.
close_connection(Conn) ->
  close_connection(Conn, ?QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0, 5000).

%% @doc Close connection with flag specified and application reason code.
-spec close_connection(connection_handler(),
                       conn_shutdown_flag(),
                       app_errno()
                      ) -> ok | {error, badarg | timeout}.
close_connection(Conn, Flags, ErrorCode) ->
  close_connection(Conn, Flags, ErrorCode, 5000).

%% @doc Close connection with flag specified and application reason code with timeout
-spec close_connection(connection_handler(),
                       conn_shutdown_flag(),
                       app_errno(),
                       timeout()) -> ok | {error, badarg | timeout}.
close_connection(Conn, Flags, ErrorCode, Timeout) ->
  case shutdown_connection(Conn, Flags, ErrorCode, Timeout) of
    {error, _} = Err ->
      Err;
    ok ->
      async_close_connection(Conn)
  end.

%% @doc Async variant of {@link close_connection/4}
-spec async_close_connection(connection_handler()) -> ok.
async_close_connection(Conn) ->
  quicer_nif:async_close_connection(Conn).

-spec async_close_connection(connection_handler(),
                             conn_shutdown_flag(),
                             app_errno()) -> ok.
async_close_connection(Conn, Flags, ErrorCode) ->
  _ = quicer_nif:async_shutdown_connection(Conn, Flags, ErrorCode),
  quicer_nif:async_close_connection(Conn).

%% @doc Accept new stream on a existing connection with stream opts
%%
%% Calling process become the owner of the new stream and it get monitored by NIF.
%%
%% Once the Calling process is dead, closing stream will be triggered. (@TODO may not be default)
%%
%% @end
-spec accept_stream(connection_handler(), stream_opts()) ->
        {ok, stream_handler()} |
        {error, badarg | internal_error | bad_pid | owner_dead} |
        {erro, timeout}.
accept_stream(Conn, Opts) ->
  accept_stream(Conn, Opts, infinity).

%% @doc Accept new stream on a existing connection with stream opts with timeout
%%
%% Calling process become the owner of the new stream and it get monitored by NIF.
%%
%% Once the Calling process is dead, closing stream will be triggered.
%%
%% @end
%% @see async_accept_stream/2
-spec accept_stream(connection_handler(), stream_opts(), timeout()) ->
        {ok, stream_handler()} |
        {error, badarg | internal_error | bad_pid | owner_dead} |
        {erro, timeout}.
accept_stream(Conn, Opts, Timeout) when is_list(Opts) ->
  accept_stream(Conn, maps:from_list(Opts), Timeout);
accept_stream(Conn, Opts, Timeout) when is_map(Opts) ->
  % @todo make_ref
  % @todo error handling
  NewOpts = maps:merge(default_stream_opts(), Opts),
  case quicer_nif:async_accept_stream(Conn, NewOpts) of
    {ok, Conn} ->
      receive
        {quic, new_stream, Stream} ->
          {ok, Stream}
      after Timeout ->
          {error, timeout}
      end;
    {error, _} = E ->
      E
  end.

%% @doc Accept new stream on a existing connection with stream opts
%%
%% Calling process become the owner of the new stream and it get monitored by NIF.
%%
%% Once the Calling process is dead, closing stream will be triggered.
%%
%% Caller process should expect to receive
%% ```
%% {quic, new_stream, stream_handler()}
%% '''
%%
%% note, it returns
%%
%% ```
%% {ok, connection_handler()}.
%% '''
%% NOT
%% ```
%% {ok, stream_handler()}.
%% '''
%% @end
%% @see async_accept_stream/2
-spec async_accept_stream(connection_handler(), proplists:proplist() | map()) ->
        {ok, connection_handler()} | {error, any()}.
async_accept_stream(Conn, Opts) when is_list(Opts) ->
  async_accept_stream(Conn, maps:from_list(Opts));
async_accept_stream(Conn, Opts) when is_map(Opts) ->
  quicer_nif:async_accept_stream(Conn, maps:merge(default_stream_opts(), Opts)).

%% @doc Start new stream in connection, return new stream handler.
%%
%% Calling process becomes the owner of the stream.
%%
%% Both client and server could start the stream
%% @end
-spec start_stream(connection_handler(), stream_opts()) ->
        {ok, stream_handler()} |
        {error, badarg | internal_error | bad_pid | owner_dead} |
        {error, stream_open_error, atom_reason()} |
        {error, stream_start_error, atom_reason()}.
start_stream(Conn, Opts) when is_list(Opts) ->
  start_stream(Conn, maps:from_list(Opts));
start_stream(Conn, Opts) when is_map(Opts) ->
  quicer_nif:start_stream(Conn, maps:merge(default_stream_opts(), Opts)).

%% @doc Send binary data over stream, blocking until send request is handled by the transport worker.
-spec send(stream_handler(), iodata()) ->
        {ok, BytesSent :: pos_integer()}          |
        {error, badarg | not_enough_mem | closed} |
        {error, stream_send_error, atom_reason()}.
send(Stream, Data) ->
  case quicer_nif:send(Stream, Data, _IsSync = 1) of
    %% @todo make ref
    {ok, _Len} = OK ->
      receive
        {quic, send_completed, Stream, _} ->
          OK
      end;
    E ->
      E
  end.

%% @doc async variant of {@link send/2}
%% Caller should expect to receive
%% ```{quic, send_completed, Stream, _}'''
-spec async_send(stream_handler(), iodata()) ->
        {ok, BytesSent :: pos_integer()}          |
        {error, badarg | not_enough_mem | closed} |
        {error, stream_send_error, atom_reason()}.
async_send(Stream, Data) ->
  quicer_nif:send(Stream, Data, _IsSync = 0).

%% @doc Recv Data (Passive mode)
%% Passive recv data from stream.
%%
%% If Len = 0, return all data in recv buffer if it is not empty.
%%             if buffer is empty, blocking for a Quic msg from stack to arrive and return all data in that msg.
%%
%% If Len > 0, desired bytes will be returned, other data would be left in recv buffer.
%%
%% Suggested to use Len=0 if caller want to buffer or reassemble the data on its own.
%%
%% note, the requested Len cannot exceed the stream recv window size specified in connection opts
%% otherwise ```{error, stream_recv_window_too_small}''' will be returned.
-spec recv(stream_handler(), Count::non_neg_integer())
          -> {ok, binary()} | {error, any()}.
recv(Stream, Count) ->
  case quicer:getopt(Stream, param_conn_settings, false) of
  {ok, Settings} ->
      case proplists:get_value(stream_recv_window_default, Settings, 0) of
        X when X < Count ->
          {error, stream_recv_window_too_small};
        _ ->
          do_recv(Stream, Count)
      end;
  {error, _} = Error ->
      Error
  end.

do_recv(Stream, Count) ->
  case quicer_nif:recv(Stream, Count) of
    {ok, not_ready} ->
      %% Data is not ready yet but last call has been reg.
      receive
        %% @todo recv_mark
        {quic, Stream, continue} ->
          recv(Stream, Count)
      end;
    {ok, Bin} ->
      {ok, Bin};
    {error, _} = E ->
      E
   end.

%% @doc Sending Unreliable Datagram
%%
%% ref: [https://datatracker.ietf.org/doc/html/draft-ietf-quic-datagram]
%% @see send/2
-spec send_dgram(connection_handler(), binary()) ->
        {ok, BytesSent :: pos_integer()}          |
        {error, badarg | not_enough_mem | closed} |
        {error, dgram_send_error, atom_reason()}.
send_dgram(Conn, Data) ->
  case quicer_nif:send_dgram(Conn, Data, _IsSync = 1) of
    %% @todo make ref
    {ok, _Len} = OK ->
      receive
        {quic, send_dgram_completed, Conn} ->
          OK
      end;
    E ->
      E
  end.

%% @doc
%%
%% ref: [https://datatracker.ietf.org/doc/html/draft-ietf-quic-datagram]
%% @see send/2
-spec shutdown_stream(stream_handler()) -> ok | {error, badarg}.
shutdown_stream(Stream) ->
  shutdown_stream(Stream, infinity).

%% @doc Shutdown stream gracefully, with app_errno 0
%%
%% returns when both endpoints closed the stream
%%
%% @see shutdown_stream/4
-spec shutdown_stream(stream_handler(), timeout()) ->
        ok |
        {error, badarg} |
        {error, timeout}.
shutdown_stream(Stream, Timeout) ->
  shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 0, Timeout).

%% @doc Start shutdown Stream process with flags and application specified error code.
%%
%% returns when stream closing is confirmed in the stack.
%%
%% Flags could be used to control the behavior like half-close.
%% @end
-spec shutdown_stream(stream_handler(),
                   stream_shutdown_flags(),
                   app_errno(),
                   timeout()) ->
        ok |
        {error, badarg} |
        {error, timeout}.
shutdown_stream(Stream, Flags, ErrorCode, Timeout) ->
  case async_shutdown_stream(Stream, Flags, ErrorCode) of
    ok ->
      receive
        {quic, closed, Stream, _IsGraceful} ->
          ok
      after Timeout ->
          {error, timeout}
      end;
    Err ->
      Err
  end.


%% @doc async variant of {@link shutdown_stream/2}
-spec async_shutdown_stream(stream_handler()) ->
        ok |
        {error, badarg | atom_reason()}.
async_shutdown_stream(Stream) ->
  quicer_nif:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 0).


%% @doc async variant of {@link shutdown_stream/4}
%% Caller should expect to receive
%% ```{quic, closed, Stream, _IsGraceful}'''
%%
-spec async_shutdown_stream(stream_handler(),
                         stream_shutdown_flags(),
                         app_errno())
                        -> ok | {error, badarg}.
async_shutdown_stream(Stream, Flags, Reason) ->
  quicer_nif:async_shutdown_stream(Stream, Flags, Reason).

%% @doc close stream handler.
-spec close_stream(stream_handler()) -> ok | {error, badarg | timeout}.
close_stream(Stream) ->
  case shutdown_stream(Stream, infinity) of
    ok ->
      async_close_stream(Stream);
    {error, _} = E ->
      E
  end.

%% @see close_stream/4
-spec close_stream(stream_handler(), timeout())
                  -> ok | {error, badarg | timeout}.
close_stream(Stream, Timeout) ->
  case shutdown_stream(Stream, Timeout) of
    ok ->
      async_close_stream(Stream);
    {error, _} = E ->
      E
  end.

%% @doc shutdown stream and then close stream handler.
%% @see close_stream/1
%% @see shutdown_stream/4
-spec close_stream(stream_handler(), stream_shutdown_flags(),
                   app_errno(), timeout())
                  -> ok | {error, badarg | timeout}.
close_stream(Stream, Flags, ErrorCode, Timeout) ->
  case shutdown_stream(Stream, Flags, ErrorCode, Timeout) of
    ok ->
      async_close_stream(Stream);
    {error, _} = E ->
      E
  end.

%% @doc async variant of {@link close_stream/4}
-spec async_close_stream(stream_handler()) -> ok | {error, badarg}.
async_close_stream(Stream) ->
  quicer_nif:async_close_stream(Stream).

%% @doc Get socket name
%% mimic {@link ssl:sockname/1}
-spec sockname(listener_handler() | connection_handler() | stream_handler()) ->
        {ok, {inet:ip_address(), inet:port_number()}} | {error, any()}.
sockname(Conn) ->
  quicer_nif:sockname(Conn).

%% @doc Get connection/stream/listener opts
%% mimic {@link ssl:getopts/2}
-spec getopt(Handle::connection_handler()
                   | stream_handler()
                   | listener_handler(),
             optname()) ->
        {ok, OptVal::any()} | {error, any()}.
getopt(Handle, Opt) ->
  quicer_nif:getopt(Handle, Opt, false).

%% @doc Get connection/stream/listener opts
%% mimic {@link ssl:getopt/2}
-spec getopt(handler(), optname(), optlevel()) ->
        not_found | %% `optname' not found, or wrong `optlevel' must be a bug.
        {ok, conn_settings()}   | %% when optname = param_conn_settings
        {error, badarg | param_error | internal_error | not_enough_mem} |
        {error, atom_reason()}.
getopt(Handle, Opt, Optlevel) ->
  quicer_nif:getopt(Handle, Opt, Optlevel).

%% @doc Set connection/stream/listener opts
%% mimic {@link ssl:setopt/2}
-spec setopt(handler(), optname(), any()) ->
        ok |
        {error, badarg | param_error | internal_error | not_enough_mem} |
        {error, atom_reason()}.
setopt(Handle, param_conn_settings, Value) when is_list(Value) ->
  setopt(Handle, param_conn_settings, maps:from_list(Value));
setopt(Handle, Opt, Value) ->
  quicer_nif:setopt(Handle, Opt, Value, false).

%% @doc get stream id with stream handler
-spec get_stream_id(Stream::stream_handler()) ->
        {ok, integer()} | {error, any()}.
get_stream_id(Stream) ->
  quicer_nif:getopt(Stream, param_stream_id, false).

%% @doc get connection state
%% mimic {@link ssl:getstat/2}
-spec getstat(connection_handler(), [inet:stat_option()]) ->
        {ok, list()} | {error, any()}.
getstat(Conn, Cnts) ->
  case quicer_nif:getopt(Conn, param_conn_statistics, false) of
    {error, _} = E ->
      E;
    {ok, Res} ->
      CntRes = lists:map(fun(Cnt) ->
                             Key = stats_map(Cnt),
                             V = proplists:get_value(Key, Res, {Key, -1}),
                             {Cnt, V}
                         end, Cnts),
      {ok, CntRes}
  end.

%% @doc Peer name
%% mimic {@link ssl:peername/1}
-spec peername(connection_handler()  | stream_handler()) ->
        {ok, {inet:ip_address(), inet:port_number()}} | {error, any()}.
peername(Handle) ->
  quicer_nif:getopt(Handle, param_conn_remote_address, false).

-spec get_conn_rid(connection_handler()) ->
        {ok, non_neg_integer()} | {error, any()}.
get_conn_rid(Conn) ->
  quicer_nif:get_conn_rid(Conn).

-spec get_stream_rid(stream_handler()) ->
        {ok, non_neg_integer()} | {error, any()}.
get_stream_rid(Stream) ->
  quicer_nif:get_stream_rid(Stream).

%% @doc list all listeners
-spec listeners() -> [{{ quicer_listener:listener_name()
                       , quicer_listener:listen_on()},
                       pid()}].
listeners() ->
  quicer_listener_sup:listeners().

%% @doc List listener with app name
-spec listener(quicer_listener:listener_name()
              | {quicer_listener:listener_name(),
                 quicer_listener:listen_on()}) -> {ok, pid()} | {error, not_found}.
listener(Name) ->
  quicer_listener_sup:listener(Name).

%% @doc set controlling process for Connection/Stream.
%% mimic {@link ssl:controlling_process/2}
%% @end
-spec controlling_process(connection_handler() | stream_handler(), pid()) ->
        ok |
        {error, closed | badarg | owner_dead | not_owner}.
controlling_process(Handler, Pid) ->
  quicer_nif:controlling_process(Handler, Pid).

%%% Internal helpers
stats_map(recv_cnt) ->
  "Recv.TotalPackets";
stats_map(recv_oct) ->
  "Recv.TotalBytes";
stats_map(send_cnt) ->
  "Send.TotalPackets";
stats_map(send_oct) ->
  "Send.TotalBytes";
stats_map(send_pend) ->
  "Send.CongestionCount";
stats_map(_) ->
  undefined.

default_stream_opts() ->
  #{active => true}.

default_conn_opts() ->
  #{ peer_bidi_stream_count => 1
   , peer_unidi_stream_count => 1
   }.
%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
