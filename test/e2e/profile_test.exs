defmodule LiteskillWeb.E2E.ProfileTest do
  use LiteskillWeb.FeatureCase, async: false

  test "user can change password", %{session: session} do
    %{password: old_password} = register_user(session)

    session
    |> visit("/profile/password")
    |> fill_in(Query.css("[name='password[current]']"), with: old_password)
    |> fill_in(Query.css("[name='password[new]']"), with: "NewSecurePassword456!")
    |> fill_in(Query.css("[name='password[confirm]']"), with: "NewSecurePassword456!")
    |> click(Query.button("Update Password"))
    |> assert_has(Query.css(".alert", text: "Password updated"))
  end
end
