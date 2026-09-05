# Frontman Server
# Copyright (C) 2025 Frontman AI
#
# Licensed under the AGPL-3.0 — see LICENSE for details.
# Additional terms apply — see AI-SUPPLEMENTARY-TERMS.md

defmodule FrontmanServer.Providers.CustomLLM do
  @moduledoc """
  LOCAL-NOAUTH PATCH — fork-only module. Not present upstream.

  Backs the generic OpenAI-compatible provider configured through the
  `CUSTOM_LLM_*` env vars (parsed in `config/runtime.exs`). Everything the fork
  adds for that provider lives here so `FrontmanServer.Providers` keeps only
  three small call sites and stays cheap to merge.
  """

  @doc """
  The env-configured custom provider, or `nil` when none is configured.
  """
  def config, do: Application.get_env(:frontman_server, :custom_llm)

  @doc """
  Resolves `<provider_id>:<model>` to an LLMDB model plus request opts.

  The model is built exactly like upstream's `resolve_custom_model/4` does for
  its DB-backed custom providers: `%LLMDB.Model{provider: :openai, ...}` with a
  request-level `base_url`. ReqLLM has no notion of custom vendors, and an
  unknown `openai` model id resolves through its inline-model fallback path —
  so the openai vendor is what makes an arbitrary OpenAI-compatible endpoint
  work. The `LLMDB.Model` shape (not a raw string) is what the execution
  pipeline's preflight (`images_supported?/1` etc.) pattern-matches on.
  """
  def llm_args(custom, model, opts) when is_binary(model) do
    [_provider, model_id] = String.split(model, ":", parts: 2)

    llm_opts =
      [api_key: api_key(custom.api_key), base_url: custom.base_url]
      |> Keyword.merge(opts)

    resolved = %LLMDB.Model{provider: :openai, id: model_id, base_url: custom.base_url}

    {:ok, {resolved, llm_opts}}
  end

  @doc """
  Builds the model-picker group for the custom provider.
  """
  def picker_group(%{provider_id: provider_id, display_name: display_name, models: models}) do
    {provider_id, %{display_name: display_name, models: models}}
  end

  # Keyless endpoints (Ollama, LM Studio, an unauthenticated LiteLLM-style
  # gateway) still need *some* api_key for the openai vendor to build a request,
  # so send a placeholder rather than refusing with :no_api_key.
  defp api_key(key) when is_binary(key) and key != "", do: key
  defp api_key(_key), do: "not-needed"
end
