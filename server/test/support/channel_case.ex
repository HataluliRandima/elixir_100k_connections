defmodule Elixir100kConnectionsWeb.ChannelCase do
  @moduledoc """
  Test case for channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import Elixir100kConnectionsWeb.ChannelCase

      @endpoint Elixir100kConnectionsWeb.Endpoint
    end
  end
end
