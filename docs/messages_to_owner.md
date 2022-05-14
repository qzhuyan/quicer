# Messages to Owner Processes

Since most of API calls are asynchronous, the API caller or the stream/connection owner can receive
async messages as following

## Messages to Stream Owner

### active received data

Data received in binary format

```erlang
{quic, binary(), stream_handler(), AbsoluteOffset::integer(), TotalBufferLength::integer(), Flag :: integer()}
```

### peer_send_shutdown

```erlang
{quic, peer_send_shutdown, stream_handler(), ErrorCode}
```

### peer_send_aborted

```erlang
{quic, peer_send_aborted, stream_handler(), ErrorCode}
```

### stream closed, shutdown_completed,

Both directions of the stream have been shut down.

```erlang
{quic, closed, stream_handler(), ConnectionShutdown:: 0 | 1}
```

### send_complete

Send call is handled by stack, caller is ok to release the sndbuffer

This message is for sync send only.

```erlang
{quic, send_complete, stream_handler(), IsSendCanceled :: 0 | 1}
```


### continue recv

This is for passive recv only, this is used to notify
caller that new data is ready in recv buffer. The data in the recv buffer
will be pulled by NIF function instead of by sending the erlang messages

see usage in: quicer:recv/2

``` erlang
{quic, continue, stream_handler()}
```

### passive mode

Running out of *active_n*, stream now is in passive mode.

Need to call setopt active_n to make it back to passive mode again

Or use quicer:recv/2 to receive in passive mode

``` erlang
{quic, passive, stream_handler()}
```

## Messages to Connection Owner

### Connection connected

``` erlang
{quic, connected, connection_handler()}
```

This message notifies the connection owner that quic connection is established(TLS handshake is done).

also see [[Accept New Connection (Server)]]


### New Stream Started

``` erlang
{quic, new_stream, stream_handler()} %% @TODO, it should carry connection_handler() as well
```

This message is sent to notify the process which is accpeting new stream.

The process become the owner of the stream.

also see [[Accept Stream (Server)]]

### Transport Shutdown

Connection has been shutdown by the transport locally, such as idle timeout.

``` erlang
{quic, transport_shutdown, connection_handler(), Status :: atom_status()}
```

### Shutdown initiated by PEER

Peer side initiated connection shutdown.

``` erlang
{quic, shutdown, connection_handler()}
```

### Shutdown Complete

The connection has completed the shutdown process and is ready to be
safely cleaned up.

``` erlang
{quic, closed, connection_handler()}
```

## Messages to Listener Owner

### New connection

``` erlang
{quic, new_conn, connection_handler()}
```

This message is sent to the process who is accepting new connections.

The process becomes the connection owner.

To complete the TLS handshake, quicer:handshake/1,2 should be called.


### Listener Stopped

```erlang
{quic, listener_stopped, listener_handler()}
```

This message is sent to the listener owner process, indicating the listener
is stopped and closed. 
