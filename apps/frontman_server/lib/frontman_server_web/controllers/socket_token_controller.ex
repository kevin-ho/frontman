# Frontman Server
# Copyright (C) 2025 Frontman AI
#
# Licensed under the AGPL-3.0 — see LICENSE for details.
# Additional terms apply — see AI-SUPPLEMENTARY-TERMS.md

defmodule FrontmanServerWeb.SocketTokenController do
  use FrontmanServerWeb, :controller

  alias FrontmanServer.Accounts

  def show(conn, _params) do
    case resolve_user(conn) do
      %Accounts.User{} = user ->
        token = Phoenix.Token.sign(conn, "user socket", user.id)
        json(conn, %{token: token})

      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Not authenticated"})
    end
  end

  defp resolve_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: %Accounts.User{} = user} -> user
      _ -> local_noauth_user()
    end
  end

  # LOCAL-NOAUTH PATCH: in local mode always issue a token for the local user.
  defp local_noauth_user do
    case Application.get_env(:frontman_server, :local_noauth_user_id) do
      nil -> nil
      user_id -> Accounts.get_user(user_id)
    end
  end
end
