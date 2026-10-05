defmodule Elixir100kConnectionsWeb.ErrorJSONTest do
  use Elixir100kConnectionsWeb.ConnCase, async: true

  test "renders 404" do
    assert Elixir100kConnectionsWeb.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert Elixir100kConnectionsWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
