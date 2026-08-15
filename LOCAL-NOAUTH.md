# LOCAL-NOAUTH mode

Run the Frontman server with WorkOS auth bypassed (single local user) and any
OpenAI-compatible LLM endpoint (9Router, LiteLLM, Mistral, Google AI Studio
via OpenAI-compat, etc.) configured purely through environment variables.

## What changed vs upstream

All local changes are marked `LOCAL-NOAUTH PATCH` in the source. Summary:

1. **Auth bypass** (gated on `LOCAL_NOAUTH_USER_ID` being set):
   - `user_auth.ex`, `user_session_controller.ex`, `user_socket.ex`,
     `socket_token_controller.ex` — requests fall back to the seeded local
     user; `GET /users/log-in` mints a real session cookie.
2. **Generic custom LLM provider** (gated on `CUSTOM_LLM_MODELS` being set):
   - `runtime.exs` reads `CUSTOM_LLM_*` vars and exposes a `:custom_llm` map.
   - `providers.ex` appends the custom group to the model picker at runtime
     and rewrites `<id>:<model>` → `openai:<model>` + `base_url` in
     `prepare_llm_args/3` (ReqLLM has no custom vendors; unknown openai model
     ids resolve via inline-model fallback).
   - `max_image_dimension/1` tolerates unknown providers (returns nil instead
     of raising) because the rewrite leaks the `openai` vendor into a lookup.
3. **`config/dev.exs`**: DB creds / port / bind from env (`PORT`, loopback
   bind for reverse-proxy TLS termination).

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
| `CUSTOM_LLM_API_KEY` | recommended | — | API key for the endpoint |
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

The DB needs the local user. **No API-key rows are needed anymore** — when
`CUSTOM_LLM_*` is configured, `UserApiKeyController.index` reports an
`"openrouter"` marker so the compiled client's `hasAnyProviderConfigured` boot
gate opens (the client only recognizes a hardcoded provider whitelist and has
no concept of a custom provider). The old recipe — seeding a decoy
`openrouter` row with a placeholder key — is retired: it polluted the model
picker with 22 cloud models that could never work on a local install.

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

## Merging upstream

All patches are marked `LOCAL-NOAUTH PATCH`. The philosophy: minimal hunk
count per file, additive files never conflict, and `providers.exs` is
upstream-identical. The high-traffic merge surfaces are `providers.ex`
(picker + prepare path) and `runtime.exs` (env reads) — everything else is
either additive or gated one-liners.

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
