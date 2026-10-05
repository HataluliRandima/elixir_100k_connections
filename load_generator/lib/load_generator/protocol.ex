defmodule LoadGenerator.Protocol do
  @moduledoc """
  The small slice of the Phoenix Channels V2 JSON wire format the load
  generator needs.

  Every frame is a JSON array:

      [join_ref, ref, topic, event, payload]

  The client joins once (`phx_join`), then sends `ping` events. Replies arrive
  as `phx_reply` with `%{"status" => "ok" | "error", "response" => ...}`.
  """

  @topic "connections:lobby"
  @join_ref "1"

  def topic, do: @topic

  @doc "The query string that selects the V2 serializer."
  def vsn_query, do: "vsn=2.0.0"

  def join_frame do
    encode([@join_ref, @join_ref, @topic, "phx_join", %{}])
  end

  @doc "A ping carrying the client's send time so the reply can be timed."
  def ping_frame(ref, sent_at_us) when is_integer(ref) do
    encode([@join_ref, Integer.to_string(ref), @topic, "ping", %{"t" => sent_at_us}])
  end

  @doc """
  Decodes a server frame into one of:

    * `{:reply, ref, status, response}`
    * `{:event, event, payload}` for pushes such as `phx_error`/`phx_close`
    * `{:error, :invalid_frame}`
  """
  def decode(text) do
    case Jason.decode(text) do
      {:ok, [_join_ref, ref, _topic, "phx_reply", %{"status" => status, "response" => response}]} ->
        {:reply, ref, status, response}

      {:ok, [_join_ref, _ref, _topic, event, payload]} ->
        {:event, event, payload}

      _ ->
        {:error, :invalid_frame}
    end
  end

  defp encode(message), do: Jason.encode!(message)
end
