# LOCAL-NOAUTH mode

Run the Frontman server with WorkOS auth bypassed (single local user) and any
OpenAI-compatible LLM endpoint (9Router, LiteLLM, Mistral, Google AI Studio
via OpenAI-compat, etc.) configured purely through environment variables.

## What changed vs upstream

All local changes are marked `LOCAL-NOAUTH PATCH` in the source. Summary:

1. **Auth bypass** (gated on `LOCAL_NOAUTH_USER_ID` being set):
   - `user_auth.ex`, `user_session_controller.ex`, `user_socket.ex`,
     `socket_token_controller.ex` — requests fall back to the seeded local
     user; `GET /users/log-in` mints a real session cookie. A
     `LOCAL_NOAUTH_USER_ID` that points at a non-existent user degrades to
     "not signed in" (real login page), it does not half-authenticate.
   - **Security posture:** in this mode the server has no authentication left.
     See *Security* below before exposing it past loopback.
2. **Generic custom LLM provider** (gated on `CUSTOM_LLM_MODELS` being set):
   - `runtime.exs` reads `CUSTOM_LLM_*` vars and exposes a `:custom_llm` map.
     `CUSTOM_LLM_BASE_URL` is required once `CUSTOM_LLM_MODELS` is set — a
     half-configured install fails at boot rather than at first request.
   - `providers.ex` **prepends** the custom group to the model picker at
     runtime, so it is the FIRST group and a fresh browser auto-selects the
     custom model as default instead of a cloud model that has no credentials
     on this install. It also rewrites `<id>:<model>` → `openai:<model>` +
     `base_url` in `prepare_llm_args/3` (ReqLLM has no custom vendors; unknown
     openai model ids resolve via inline-model fallback).
   - `CUSTOM_LLM_API_KEY` is optional: when unset, a placeholder key is sent so
     keyless endpoints (Ollama, LM Studio, an unauthenticated gateway) work.
   - `max_image_dimension/1` tolerates unknown providers (returns nil instead
     of raising) because the rewrite leaks the `openai` vendor into a lookup.
3. **`config/dev.exs`**: DB creds / port / bind from env (`PORT`, loopback
   bind for reverse-proxy TLS termination).
4. **Client** (`Client__State__StateReducer.res`): `hasAnyProviderConfigured`
   treats any model group id outside the client's known cloud set
   (openai / anthropic / openrouter / nvidia / fireworks) as "a working LLM
   exists", which opens the provider-setup gate for a custom provider. Rebuild
   the bundle after touching this — see *Building the client from source*.
5. **`apps/frontman_server/Makefile`**: `make dev` / `make debug-task` no longer
   wrap in `op run` — WorkOS secrets are unused in local mode, so the 1Password
   CLI is not required.

Two further changes are **not** local-mode specific and carry no
`LOCAL-NOAUTH PATCH` marker, because they are upstream bug fixes kept on the
`upstream-fixes` branch for PR-ing back:

- `tool_executor.ex` — a malformed tool call (`{:error, {:invalid_tool_arguments, _}}`)
  persists an error tool result instead of killing the execution loop.
- `swarm_ai/llm/response.ex` — repairs streamed tool-call arguments that lost
  their leading `{`.

Elixir itself is installed via the official installer
(https://elixir-lang.org/install.html) — nothing is vendored in this repo.

The upstream `providers.exs` is untouched; the custom provider never touches
compile-time config, so env changes need only a service restart.

## Environment variables

| Var | Required | Default | Meaning |
|---|---|---|---|
| `LOCAL_NOAUTH_USER_ID` | yes (for auth bypass) | — | UUID of the seeded local user |
| `CUSTOM_LLM_MODELS` | yes (for custom provider) | — | Comma-separated `Display Name\|model-id` entries |
| `CUSTOM_LLM_BASE_URL` | yes (when models set) | — | OpenAI-compatible base URL (must end in `/v1`) |
| `CUSTOM_LLM_API_KEY` | no | placeholder | API key for the endpoint; omit for keyless local endpoints |
| `CUSTOM_LLM_PROVIDER_ID` | no | `custom` | Picker group id (becomes `<id>:<model>` prefix) |
| `CUSTOM_LLM_DISPLAY_NAME` | no | `Custom LLM` | Picker group display name |

All are read in `runtime.exs` **after** Dotenvy loads `envs/.dev.env` and
`envs/.dev.overrides.env` — put deployment-specific values in
`.dev.overrides.env` (gitignored) and they survive restarts.

## Example: Mistral cloud

```bash
# envs/.dev.overrides.env
CUSTOM_LLM_PROVIDER_ID=mistral
CUSTOM_LLM_DISPLAY_NAME=Mistral
CUSTOM_LLM_BASE_URL=https://api.mistral.ai/v1
CUSTOM_LLM_API_KEY=...
CUSTOM_LLM_MODELS=Mistral Large|mistral-large-latest,Codestral|codestral-latest
```

## Example: local gateway (9Router / LiteLLM style)

```bash
CUSTOM_LLM_PROVIDER_ID=9router
CUSTOM_LLM_DISPLAY_NAME=9Router
CUSTOM_LLM_BASE_URL=http://127.0.0.1:4000/v1
CUSTOM_LLM_API_KEY=...
CUSTOM_LLM_MODELS=Main|my-main-combo
```

Restart the service after changing any of these — they're read at boot.

## First-run seeding

The DB needs the local user, and nothing else. **No API-key rows are needed** —
the client-side `hasAnyProviderConfigured` patch (item 4 above) opens the
provider-setup gate on the presence of the custom model group itself.

Two older recipes are retired and should not be reintroduced: seeding a decoy
`openrouter` API-key row (it polluted the picker with 22 cloud models that
could never work here), and the server-side `UserApiKeyController.index`
`"openrouter"` marker shim (replaced by the client patch, so
`user_api_key_controller.ex` is upstream-identical).

```bash
cd apps/frontman_server
mix run -e '
alias FrontmanServer.{Repo, Accounts, Accounts.User, Providers, Accounts.Scope}
{:ok, _} = Application.ensure_all_started(:frontman_server)
case Accounts.get_user_by_email("you@local.test") do
  %User{} = u -> u
  nil -> {:ok, u} = Accounts.register_user(%{email: "you@local.test", name: "You", password: "local_noauth_not_used"}); u
end |> tap(fn u ->
  IO.puts("LOCAL_NOAUTH_USER_ID=#{u.id}")
end)
'
# put the printed UUID into envs/.dev.overrides.env as LOCAL_NOAUTH_USER_ID
```

## Security

With `LOCAL_NOAUTH_USER_ID` set, the server has **no authentication**. Every
request is the local user, `GET /users/log-in` mints a session cookie on demand,
and `/api/socket-token` issues a socket token to anyone who asks.

Two consequences worth knowing:

- `config/dev.exs` still sets `check_origin: false`. Combined with the auth
  bypass, any web page open in the same browser can connect to the socket on
  `http://127.0.0.1:4000` and drive the agent — which writes files in your repo.
  Tighten it to an explicit list when you care:
  `check_origin: ["//localhost:4000", "//127.0.0.1:4000"]`.
- Binding to loopback does not protect against the above (the caller is a page
  in your browser, not a remote host). If you expose the server past loopback
  via a reverse proxy or Tailscale Serve, put authentication on the *proxy* —
  the app has none left.

## Merging upstream

All local-mode patches are marked `LOCAL-NOAUTH PATCH`. The philosophy: minimal
hunk count per file, additive files never conflict, and `providers.exs` is
upstream-identical. The high-traffic merge surfaces are `providers.ex`
(picker + prepare path) and `runtime.exs` (env reads) — everything else is
either additive or a gated `case` at the top of a function, with the upstream
body moved untouched into a `*_original/1` helper.

The two upstream bug fixes also live on the **`upstream-fixes`** branch (off the
same upstream base, no local-mode code). Send those as PRs; if upstream takes
them, drop them from this branch on the next merge.

## Building the client from source

The overlay UI served at `/frontman` is **built from this repo** (`libs/client`,
ReScript + React). Do not fetch `frontman.es.js` from `app.frontman.sh` — the
CDN bundle is upstream's build and cannot carry our client patches.

```bash
corepack enable --install-directory ~/.local/bin   # once; yarn 4 via corepack
cd <repo>
yarn install                                        # full monorepo workspace
make -C libs/client build-standalone                # rescript build + vite bundle
cp libs/client/dist/frontman.es.js <app>/public/frontman/
cp libs/client/dist/frontman.css   <app>/public/frontman/
```

Output is a single self-contained ES module (`dist/frontman.es.js`, ~2.6 MB,
React bundled) plus `frontman.css`. Sanity check: a bundle
megabyte-for-megabyte identical to upstream's CDN build (± a few hundred
bytes for patches) means the pipeline is faithful. The client patch that
matters: `hasAnyProviderConfigured` in
`libs/client/src/state/Client__State__StateReducer.res` — a model group id
outside the known cloud set opens the provider gate (see commit message).
After any client-source change, rebuild and redeploy the bundle.
