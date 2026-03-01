defmodule LiteskillWeb.E2E.RegistrationTest do
  use LiteskillWeb.FeatureCase, async: false

  test "successful registration redirects to home", %{session: session} do
    session
    |> visit("/register")
    |> fill_in(Query.css("#user_name"), with: "New User")
    |> fill_in(Query.css("#user_email"), with: "newuser@example.com")
    |> fill_in(Query.css("#user_password"), with: "ValidPassword123!")
    |> click(Query.button("Register"))
    |> assert_has(Query.css("[data-role=chat-container]", count: 1))
  end

  test "duplicate email shows error", %{session: session} do
    %{email: email, password: password} = register_user(session)

    session
    |> visit("/register")
    |> fill_in(Query.css("#user_name"), with: "Another User")
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: password)
    |> click(Query.button("Register"))
    |> assert_has(Query.css("[data-phx-id]", text: "has already been taken"))
  end
end
