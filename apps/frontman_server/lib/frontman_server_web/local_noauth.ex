# Frontman Server
# Copyright (C) 2025 Frontman AI
#
# Licensed under the AGPL-3.0 — see LICENSE for details.
# Additional terms apply — see AI-SUPPLEMENTARY-TERMS.md

defmodule FrontmanServerWeb.LocalNoauth do
  @moduledoc """
  LOCAL-NOAUTH PATCH — fork-only module. Not present upstream.

  Web-layer helpers for the fork's single-user local mode. Lives inside the
  `FrontmanServerWeb` boundary so controllers can call it without exporting
  anything new from the `FrontmanServer.Providers` boundary.
  """

  # One of the provider ids the compiled client's setup gate recognises
  # (openrouter / nvidia / fireworks / anthropic). See api_key_gate_markers/1.
  @client_gate_marker "openrouter"

  @doc """
  Adds a marker to the saved-API-key provider list so the compiled client's
  provider-setup gate opens when a `CUSTOM_LLM_*` provider is configured.

  The client decides "is any provider configured?" purely from the
  `/api/user/api-keys` response, and recognises only its four hardcoded cloud
  providers — it has no concept of an env-configured provider, so without this it
  parks on the setup screen forever.

  Applied at the controller boundary, NOT inside
  `FrontmanServer.Providers.list_api_key_providers/1`: the model picker calls that
  function directly, so keeping the marker out of it means the picker never
  advertises cloud models this install has no credentials for.

  Doing it server-side keeps `Client__State__StateReducer.res` upstream-identical,
  which means the stock client bundle works and no rebuild is needed after an
  upstream merge.
  """
  def api_key_gate_markers(providers) when is_list(providers) do
    case Application.get_env(:frontman_server, :custom_llm) do
      nil -> providers
      %{} -> Enum.uniq([@client_gate_marker | providers])
    end
  end
end
