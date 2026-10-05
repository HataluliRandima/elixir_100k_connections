defmodule Elixir100kConnectionsWeb.ConnectionChannelTest do
  # Not async: the counters are node-global, so tests assert on deltas and
  # must not interleave.
  use Elixir100kConnectionsWeb.ChannelCase, async: false

  alias Elixir100kConnections.Metrics
  alias Elixir100kConnectionsWeb.{ConnectionChannel, LoadSocket}

  defp join_lobby do
    {:ok, socket} = connect(LoadSocket, %{})
    {:ok, reply, socket} = subscribe_and_join(socket, ConnectionChannel, "connections:lobby")
    {reply, socket}
  end

  describe "connect" do
    test "assigns a unique client id to every socket" do
      {:ok, a} = connect(LoadSocket, %{})
      {:ok, b} = connect(LoadSocket, %{})

      assert is_integer(a.assigns.client_id)
      assert a.assigns.client_id != b.assigns.client_id
    end

    test "counts accepted sockets" do
      before = Metrics.get(:sockets_accepted)
      {:ok, _socket} = connect(LoadSocket, %{})
      assert Metrics.get(:sockets_accepted) == before + 1
    end

    test "counts rejected sockets as errors" do
      before = Metrics.get(:socket_errors)
      assert :error = connect(LoadSocket, %{"reject" => "true"})
      assert Metrics.get(:socket_errors) == before + 1
    end
  end

  describe "join" do
    test "replies with the server-assigned client id" do
      {reply, socket} = join_lobby()
      assert reply == %{client_id: socket.assigns.client_id}
    end

    test "increments the active connection gauge" do
      before = Metrics.get(:active_connections)
      {_reply, _socket} = join_lobby()
      assert Metrics.get(:active_connections) == before + 1
    end

    test "rejects unknown topics" do
      {:ok, socket} = connect(LoadSocket, %{})
      before = Metrics.get(:join_errors)

      assert {:error, %{reason: "unknown topic"}} =
               subscribe_and_join(socket, ConnectionChannel, "connections:other")

      assert Metrics.get(:join_errors) == before + 1
    end
  end

  describe "ping" do
    test "echoes the payload with the client id and a server timestamp" do
      {_reply, socket} = join_lobby()
      client_id = socket.assigns.client_id

      ref = push(socket, "ping", %{"t" => 123})

      assert_reply ref, :ok, %{echo: %{"t" => 123}, client_id: ^client_id, server_time_us: ts}
      assert is_integer(ts)
    end

    test "counts received and sent messages" do
      {_reply, socket} = join_lobby()
      received = Metrics.get(:messages_received)
      sent = Metrics.get(:messages_sent)

      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, _

      assert Metrics.get(:messages_received) == received + 1
      assert Metrics.get(:messages_sent) == sent + 1
    end

    test "replies with an error to unknown events" do
      {_reply, socket} = join_lobby()
      ref = push(socket, "nope", %{})
      assert_reply ref, :error, %{reason: "unknown event"}
    end
  end

  describe "disconnect" do
    test "a client leaving decrements active connections and counts a disconnect" do
      {_reply, socket} = join_lobby()
      active = Metrics.get(:active_connections)
      disconnects = Metrics.get(:disconnects)

      Process.unlink(socket.channel_pid)
      ref = leave(socket)
      assert_reply ref, :ok

      wait_until_down(socket.channel_pid)
      assert Metrics.get(:active_connections) == active - 1
      assert Metrics.get(:disconnects) == disconnects + 1
    end

    test "the transport closing decrements active connections" do
      {_reply, socket} = join_lobby()
      active = Metrics.get(:active_connections)

      Process.unlink(socket.channel_pid)
      close(socket)

      wait_until_down(socket.channel_pid)
      assert Metrics.get(:active_connections) == active - 1
    end
  end

  defp wait_until_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end
end
