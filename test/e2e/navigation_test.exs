defmodule LiteskillWeb.E2E.NavigationTest do
  use LiteskillWeb.FeatureCase, async: false

  test "unauthenticated user is redirected to login", %{session: session} do
    session
    |> visit("/")
    |> assert_has(Query.button("Sign In"))
  end

  test "authenticated user can navigate to profile", %{session: session} do
    register_user(session)

    session
    |> visit("/profile")
    |> assert_has(Query.css("h2", text: "Profile"))
  end
end
