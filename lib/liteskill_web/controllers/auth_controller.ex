defmodule LiteskillWeb.AuthController do
  use LiteskillWeb, :controller

  plug Ueberauth

  alias Liteskill.Accounts
  alias LiteskillWeb.Plugs.SessionHelpers

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    user_attrs = %{
      email: auth.info.email,
      name: auth.info.name,
      avatar_url: auth.info.image,
      oidc_sub: auth.uid,
      oidc_issuer: auth.extra.raw_info.userinfo["iss"] || "unknown",
      oidc_claims: auth.extra.raw_info.userinfo || %{}
    }

    conn_info = %{
      ip_address: SessionHelpers.client_ip(conn),
      user_agent: SessionHelpers.client_user_agent(conn)
    }

    case Accounts.find_or_create_from_oidc(user_attrs) do
      {:ok, user} ->
        {:ok, session} = Accounts.create_session(user.id, conn_info)

        Accounts.log_auth_event(%{
          event_type: "login_success",
          user_id: user.id,
          ip_address: conn_info.ip_address,
          user_agent: conn_info.user_agent,
          metadata: %{"method" => "oidc"}
        })

        conn
        |> put_session(:session_token, session.id)
        |> json(%{ok: true, user_id: user.id})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "failed to authenticate"})
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn_info = %{
      ip_address: SessionHelpers.client_ip(conn),
      user_agent: SessionHelpers.client_user_agent(conn)
    }

    Accounts.log_auth_event(%{
      event_type: "login_failure",
      ip_address: conn_info.ip_address,
      user_agent: conn_info.user_agent,
      metadata: %{"method" => "oidc"}
    })

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "authentication failed"})
  end

  def logout(conn, _params) do
    session_token = get_session(conn, :session_token)

    conn_info = %{
      ip_address: SessionHelpers.client_ip(conn),
      user_agent: SessionHelpers.client_user_agent(conn)
    }

    if session_token do
      case Accounts.validate_session(session_token) do
        %{user_id: user_id} ->
          Accounts.log_auth_event(%{
            event_type: "logout",
            user_id: user_id,
            ip_address: conn_info.ip_address,
            user_agent: conn_info.user_agent
          })

        _ ->
          :ok
      end

      Accounts.delete_session(session_token)
    end

    conn
    |> configure_session(drop: true)
    |> json(%{ok: true})
  end
end
