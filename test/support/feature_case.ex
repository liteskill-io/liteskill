defmodule LiteskillWeb.FeatureCase do
  @moduledoc """
  Case template for Wallaby browser-based E2E tests.

  Tests using this case template are excluded from `mix test` by default
  and run via `mix test.e2e` (or `mix test --include e2e`).
  """
  use ExUnit.CaseTemplate
  use Wallaby.DSL

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      use Wallaby.DSL

      import LiteskillWeb.FeatureCase

      @moduletag :e2e
    end
  end

  setup do
    :ok = Sandbox.checkout(Liteskill.Repo)
    Sandbox.mode(Liteskill.Repo, {:shared, self()})
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Liteskill.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata)
    on_exit(fn -> Wallaby.end_session(session) end)
    {:ok, session: session}
  end

  @doc "Register a new user via the browser registration form."
  def register_user(session, attrs \\ %{}) do
    name = Map.get(attrs, :name, "Test User")
    email = Map.get(attrs, :email, "e2e-#{System.unique_integer([:positive])}@example.com")
    password = Map.get(attrs, :password, "ValidPassword123!")

    session
    |> visit("/register")
    |> fill_in(Query.css("#user_name"), with: name)
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: password)
    |> click(Query.button("Register"))

    %{session: session, name: name, email: email, password: password}
  end

  @doc "Log in an existing user via the browser login form."
  def login_user(session, email, password) do
    session
    |> visit("/login")
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: password)
    |> click(Query.button("Sign In"))
  end

  @doc "Register a new user and return session + credentials."
  def register_and_login(session, attrs \\ %{}) do
    register_user(session, attrs)
  end
end
