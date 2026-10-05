defmodule LoadGenerator.ProtocolTest do
  use ExUnit.Case, async: true

  alias LoadGenerator.Protocol

  test "join frame follows the Phoenix V2 array format" do
    assert Jason.decode!(Protocol.join_frame()) == [
             "1",
             "1",
             "connections:lobby",
             "phx_join",
             %{}
           ]
  end

  test "ping frame carries the ref and send time" do
    assert Jason.decode!(Protocol.ping_frame(7, 123)) ==
             ["1", "7", "connections:lobby", "ping", %{"t" => 123}]
  end

  test "decodes replies" do
    frame =
      ~s(["1","7","connections:lobby","phx_reply",{"status":"ok","response":{"echo":{"t":123}}}])

    assert Protocol.decode(frame) == {:reply, "7", "ok", %{"echo" => %{"t" => 123}}}
  end

  test "decodes server pushes" do
    frame = ~s(["1",null,"connections:lobby","phx_error",{}])
    assert Protocol.decode(frame) == {:event, "phx_error", %{}}
  end

  test "rejects garbage" do
    assert Protocol.decode("not json") == {:error, :invalid_frame}
    assert Protocol.decode(~s({"a":1})) == {:error, :invalid_frame}
  end
end
