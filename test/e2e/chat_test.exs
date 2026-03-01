defmodule LiteskillWeb.E2E.ChatTest do
  use LiteskillWeb.FeatureCase, async: false

  test "home page renders chat UI after login", %{session: session} do
    register_user(session)

    session
    |> visit("/")
    |> assert_has(Query.css("h1", text: "What can I help you with?"))
    |> assert_has(Query.css("#message-input"))
  end

  test "message textarea is focusable", %{session: session} do
    register_user(session)

    session
    |> visit("/")
    |> click(Query.css("#message-input"))
    |> fill_in(Query.css("#message-input"), with: "Hello, world!")
    |> assert_has(Query.css("#message-input", text: "Hello, world!"))
  end
end
