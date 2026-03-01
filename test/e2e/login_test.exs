defmodule LiteskillWeb.E2E.LoginTest do
  use LiteskillWeb.FeatureCase, async: false

  test "valid login redirects to home", %{session: session} do
    %{email: email, password: password} = register_user(session)

    session
    |> visit("/login")
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: password)
    |> click(Query.button("Sign In"))
    |> assert_has(Query.css("[data-role=chat-container]", count: 1))
  end

  test "invalid password shows error", %{session: session} do
    %{email: email} = register_user(session)

    session
    |> visit("/login")
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: "WrongPassword999!")
    |> click(Query.button("Sign In"))
    |> assert_has(Query.css(".alert", text: "Invalid email or password"))
  end
end
