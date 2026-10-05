defmodule LoadGenerator.Client do
  @moduledoc """
  One simulated WebSocket client = one BEAM process.

  Mint is process-less: the connection is a data structure owned by this
  GenServer, and socket data arrives as ordinary messages. So a client costs
  one lightweight process plus one TCP socket, not an OS process or thread.

  Lifecycle:

      :connecting  TCP connect + HTTP upgrade request
      :upgrading   waiting for the 101 Switching Protocols response
      :joining     WebSocket open, phx_join sent
      :joined      pinging every `message_interval_ms`
      :closing     close frame sent, waiting for the server to close

  Every outcome is recorded in `LoadGenerator.Stats`; the process itself
  always exits `:normal` so the supervisor never restarts it.
  """

  use GenServer, restart: :temporary

  alias LoadGenerator.{Histogram, Protocol, Stats}

  @upgrade_timeout_ms 10_000
  @close_timeout_ms 5_000

  # Mint sizes the socket's user-space receive buffer as
  # max(sndbuf, recbuf, buffer). On Linux loopback the kernel reports a
  # ~2.5 MB sndbuf, so every client would reserve ~2.5 MB of binary memory
  # it never uses (found in the first 1,000-connection run). Our frames are
  # under 200 bytes; 16 KB is plenty.
  @socket_buffer_bytes 16_384

  defstruct [
    :stats,
    :settings,
    :conn,
    :ref,
    :websocket,
    :client_id,
    :started_at,
    :awaiting_ref,
    :timer,
    phase: :connecting,
    next_ref: 2,
    status: nil,
    resp_headers: []
  ]

  @doc """
  `settings` is a map with `:host`, `:port`, `:path`, `:source_ip`,
  `:connect_timeout_ms`, `:message_interval_ms` and `:connection_duration_ms`.
  """
  def start_link({stats, settings}) do
    GenServer.start_link(__MODULE__, {stats, settings})
  end

  @doc "Asks the client to close its connection cleanly."
  def close(pid), do: send(pid, :close)

  ## Connecting

  @impl true
  def init({stats, settings}) do
    # Connecting happens in handle_continue so that start_child returns
    # immediately and the runner can keep its ramp-up schedule.
    {:ok, %__MODULE__{stats: stats, settings: settings}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{stats: stats, settings: settings} = state) do
    Stats.increment(stats, :attempted)
    started_at = now_us()

    transport_opts =
      [timeout: settings.connect_timeout_ms] ++
        if settings.source_ip, do: [ip: settings.source_ip], else: []

    with {:ok, conn} <-
           Mint.HTTP.connect(:http, settings.host, settings.port,
             protocols: [:http1],
             transport_opts: transport_opts
           ),
         :ok <- shrink_buffer(conn),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, settings.path, []) do
      timer = Process.send_after(self(), :upgrade_timeout, @upgrade_timeout_ms)

      {:noreply,
       %{state | conn: conn, ref: ref, started_at: started_at, phase: :upgrading, timer: timer}}
    else
      {:error, reason} -> fail(state, reason)
      {:error, conn, reason} -> fail(%{state | conn: conn}, reason)
    end
  end

  ## Timers and control messages

  @impl true
  def handle_info(:upgrade_timeout, %{phase: phase} = state)
      when phase in [:upgrading, :joining] do
    fail(state, :upgrade_timeout)
  end

  def handle_info(:ping, %{phase: :joined} = state) do
    state = maybe_count_timeout(state)
    ref = state.next_ref
    sent_at = now_us()

    case send_text(state, Protocol.ping_frame(ref, sent_at)) do
      {:ok, state} ->
        Stats.increment(state.stats, :messages_sent)

        state =
          schedule_ping(%{state | next_ref: ref + 1, awaiting_ref: Integer.to_string(ref)})

        {:noreply, state}

      {:error, state, reason} ->
        disconnected(state, reason)
    end
  end

  def handle_info(:lifetime_expired, %{phase: :joined} = state), do: start_close(state)
  def handle_info(:close, %{phase: :joined} = state), do: start_close(state)

  # Asked to close before the join completed: count it as a failure to
  # connect within the test window.
  def handle_info(:close, %{phase: phase} = state)
      when phase in [:connecting, :upgrading, :joining] do
    fail(state, :closed_before_join)
  end

  def handle_info(:close_timeout, %{phase: :closing} = state), do: finish_close(state)

  # Stale timers from a previous phase.
  def handle_info(msg, state)
      when msg in [:upgrade_timeout, :ping, :lifetime_expired, :close, :close_timeout] do
    {:noreply, state}
  end

  ## Socket data

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, reason, _responses} ->
        connection_lost(%{state | conn: conn}, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_responses([], state), do: {:noreply, state}

  defp handle_responses([response | rest], state) do
    case handle_response(response, state) do
      {:cont, state} -> handle_responses(rest, state)
      stop -> stop
    end
  end

  # HTTP upgrade response
  defp handle_response({:status, ref, status}, %{ref: ref} = state),
    do: {:cont, %{state | status: status}}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state),
    do: {:cont, %{state | resp_headers: headers}}

  defp handle_response({:done, ref}, %{ref: ref, phase: :upgrading} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket, phase: :joining, resp_headers: []}

        case send_text(state, Protocol.join_frame()) do
          {:ok, state} -> {:cont, state}
          {:error, state, reason} -> fail(state, reason)
        end

      {:error, conn, %Mint.WebSocket.UpgradeFailureError{status_code: code}} ->
        fail(%{state | conn: conn}, {:http_status, code})

      {:error, conn, reason} ->
        fail(%{state | conn: conn}, reason)
    end
  end

  # WebSocket frames
  defp handle_response({:data, ref, data}, %{ref: ref, websocket: websocket} = state)
       when websocket != nil do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} -> handle_frames(frames, %{state | websocket: websocket})
      {:error, websocket, reason} -> connection_lost(%{state | websocket: websocket}, reason)
    end
  end

  defp handle_response({:error, ref, reason}, %{ref: ref} = state),
    do: connection_lost(state, reason)

  defp handle_response(_other, state), do: {:cont, state}

  defp handle_frames([], state), do: {:cont, state}

  defp handle_frames([frame | rest], state) do
    case handle_frame(frame, state) do
      {:cont, state} -> handle_frames(rest, state)
      stop -> stop
    end
  end

  defp handle_frame({:text, text}, state), do: handle_message(Protocol.decode(text), state)

  defp handle_frame({:ping, data}, state) do
    case send_frame(state, {:pong, data}) do
      {:ok, state} -> {:cont, state}
      {:error, state, reason} -> connection_lost(state, reason)
    end
  end

  defp handle_frame({:close, _code, _reason}, %{phase: :closing} = state), do: finish_close(state)

  defp handle_frame({:close, code, _reason}, state),
    do: connection_lost(state, {:server_close, code})

  defp handle_frame(_frame, state), do: {:cont, state}

  # Join reply
  defp handle_message(
         {:reply, "1", "ok", %{"client_id" => client_id}},
         %{phase: :joining} = state
       ) do
    cancel_timer(state.timer)
    Histogram.record(state.stats.connect_latency, now_us() - state.started_at)
    Stats.client_opened(state.stats)

    state = %{state | phase: :joined, client_id: client_id, timer: nil}
    state = schedule_first_ping(state)
    schedule_lifetime(state)
    {:cont, state}
  end

  defp handle_message({:reply, "1", "error", response}, %{phase: :joining} = state) do
    fail(state, {:join_error, response["reason"] || inspect(response)})
  end

  # Ping reply
  defp handle_message({:reply, ref, "ok", %{"echo" => %{"t" => sent_at}}}, state)
       when is_integer(sent_at) do
    Stats.increment(state.stats, :messages_received)
    Histogram.record(state.stats.message_rtt, now_us() - sent_at)

    state =
      if ref == state.awaiting_ref,
        do: %{state | awaiting_ref: nil},
        else: state

    {:cont, state}
  end

  defp handle_message({:event, event, _payload}, state)
       when event in ["phx_error", "phx_close"] do
    connection_lost(state, {:channel, event})
  end

  defp handle_message(_message, state), do: {:cont, state}

  ## Pings

  # The first ping is spread uniformly over one interval. Without this jitter,
  # every client that joined in the same tick would ping in the same tick
  # forever, turning a smooth load into periodic spikes.
  defp schedule_first_ping(%{settings: %{message_interval_ms: 0}} = state), do: state

  defp schedule_first_ping(%{settings: %{message_interval_ms: interval}} = state) do
    Process.send_after(self(), :ping, :rand.uniform(interval))
    state
  end

  defp schedule_ping(%{settings: %{message_interval_ms: interval}} = state) do
    Process.send_after(self(), :ping, interval)
    state
  end

  defp maybe_count_timeout(%{awaiting_ref: nil} = state), do: state

  defp maybe_count_timeout(state) do
    Stats.increment(state.stats, :message_timeouts)
    %{state | awaiting_ref: nil}
  end

  defp schedule_lifetime(%{settings: %{connection_duration_ms: nil}}), do: :ok

  defp schedule_lifetime(%{settings: %{connection_duration_ms: ms}}),
    do: Process.send_after(self(), :lifetime_expired, ms)

  ## Closing

  defp start_close(state) do
    case send_frame(state, :close) do
      {:ok, state} ->
        timer = Process.send_after(self(), :close_timeout, @close_timeout_ms)
        {:noreply, %{state | phase: :closing, timer: timer}}

      {:error, state, _reason} ->
        # The socket is already gone; nothing left to close politely.
        finish_close(state)
    end
  end

  defp finish_close(state) do
    Stats.client_closed(state.stats, :closed)
    {:stop, :normal, close_conn(state)}
  end

  ## Failure paths

  # Never reached :joined.
  defp fail(state, reason) do
    cancel_timer(state.timer)
    Stats.increment(state.stats, :failed)
    Stats.record_error(state.stats, normalize(reason))
    {:stop, :normal, close_conn(state)}
  end

  # Was joined, and the connection went away without us asking.
  defp disconnected(state, reason) do
    Stats.client_closed(state.stats, :disconnected)
    Stats.record_error(state.stats, {:disconnected, normalize(reason)})
    {:stop, :normal, close_conn(state)}
  end

  defp connection_lost(%{phase: :joined} = state, reason), do: disconnected(state, reason)
  defp connection_lost(%{phase: :closing} = state, _reason), do: finish_close(state)
  defp connection_lost(state, reason), do: fail(state, reason)

  defp normalize(%Mint.TransportError{reason: reason}), do: reason
  defp normalize(%Mint.HTTPError{reason: reason}), do: reason
  defp normalize(%{__exception__: true} = error), do: error.__struct__ |> inspect()
  defp normalize(reason), do: reason

  ## Helpers

  defp shrink_buffer(conn) do
    :inet.setopts(Mint.HTTP.get_socket(conn), buffer: @socket_buffer_bytes)
  end

  defp send_text(state, text), do: send_frame(state, {:text, text})

  defp send_frame(%{websocket: websocket, conn: conn, ref: ref} = state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}

      {:error, conn, reason} ->
        {:error, %{state | conn: conn}, reason}
    end
  end

  defp close_conn(%{conn: nil} = state), do: state

  defp close_conn(%{conn: conn} = state) do
    {:ok, conn} = Mint.HTTP.close(conn)
    %{state | conn: conn}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp now_us, do: System.monotonic_time(:microsecond)
end
