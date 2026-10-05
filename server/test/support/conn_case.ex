defmodule Elixir100kConnectionsWeb.ConnCase do
  @moduledoc """
  Test case for controller tests that build a `Plug.Conn`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint Elixir100kConnectionsWeb.Endpoint

      use Elixir100kConnectionsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Elixir100kConnectionsWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
