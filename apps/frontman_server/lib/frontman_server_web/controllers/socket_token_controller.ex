# Frontman Server
# Copyright (C) 2025 Frontman AI
#
# Licensed under the AGPL-3.0 — see LICENSE for details.
# Additional terms apply — see AI-SUPPLEMENTARY-TERMS.md

defmodule FrontmanServerWeb.SocketTokenController do
  use FrontmanServerWeb, :controller

  alias FrontmanServer.Accounts

  def show(conn, _params) do
    # LOCAL-NOAUTH PATCH: in local mode always issue a token for the local user.
    local_user_id = Application.get_env(:frontman_server, :local_noauth_user_id)

    resolved_user =
      case conn.assigns[:current_scope] do
        %{user: %Accounts.User{} = u} ->
          u

        _ when not is_nil(local_user_id) ->
          Accounts.get_user(local_user_id)
      end

    case resolved_user do
      %Accounts.User{} = user ->
        token = Phoenix.Token.sign(conn, "user socket", user.id)
        json(conn, %{token: token})

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Not authenticated"})
    end
  end
end
