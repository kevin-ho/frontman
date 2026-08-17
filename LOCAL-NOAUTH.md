# LOCAL-NOAUTH mode

Run the Frontman server with WorkOS auth bypassed (single local user) and any
OpenAI-compatible LLM endpoint (9Router, LiteLLM, Mistral, Google AI Studio
via OpenAI-compat, etc.) configured purely through environment variables.

## What changed vs upstream

All local changes are marked `LOCAL-NOAUTH PATCH` in the source. Summary:

1. **Auth bypass** (gated on `LOCAL_NOAUTH_USER_ID` being set):
   - `user_auth.ex`, `user_session_controller.ex`, `socket_token_controller.ex`
     — requests fall back to the seeded local user; `GET /users/log-in` mints a
     real session cookie. A `LOCAL_NOAUTH_USER_ID` that points at a
     non-existent user degrades to "not signed in" (real login page), it does
     not half-authenticate.
   - `user_socket.ex` is **upstream-identical** — the socket needs no patch,
     because in local mode the client already gets a token from
     `/api/socket-token` (or a cookie from the login page), which the upstream
     `get_scope_from_token` / `get_scope_from_session` paths accept.
   - **Security posture:** in this mode the server has no authentication left.
     See *Security* below before exposing it past loopback.
2. **Generic custom LLM provider** (gated on `CUSTOM_LLM_MODELS` being set):
   - `runtime.exs` reads `CUSTOM_LLM_*` vars and exposes a `:custom_llm` map.
     `CUSTOM_LLM_BASE_URL` is required once `CUSTOM_LLM_MODELS` is set — a
     half-configured install fails at boot rather than at first request.
   - `providers/custom_llm.ex` (**new file, fork-only**) holds the rewrite
     `<id>:<model>` → `openai:<model>` + `base_url`, the key placeholder, and
     the picker group. ReqLLM has no custom vendors; unknown openai model ids
     resolve via its inline-model fallback.
   - `providers.ex` keeps only three small call sites into that module:
     `prepare_llm_args/3`, `max_image_dimension/1`, and the picker, where the
     custom group is **prepended** so it is the FIRST group — a fresh browser
     auto-selects the custom model instead of a cloud model with no credentials
     on this install. `provider_config/1` is upstream-identical.
   - `CUSTOM_LLM_API_KEY` is optional: when unset, a placeholder key is sent so
     keyless endpoints (Ollama, LM Studio, an unauthenticated gateway) work.
   - `CUSTOM_LLM_PROVIDER_ID` **must not** be `openai`, `anthropic`,
     `openrouter`, `nvidia` or `fireworks`. The compiled client treats those
     five as "cloud provider, needs a saved key/OAuth", so reusing one leaves
     the overlay stuck on the setup screen. `runtime.exs` refuses to boot in
     that case rather than letting you debug a dead gate.
3. **`config/dev.exs`**: DB creds / port / bind from env (`PORT`, loopback
   bind for reverse-proxy TLS termination), and `check_origin` is an allowlist
   instead of upstream's `false` — extend it with `FRONTMAN_ALLOWED_ORIGINS`.
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
| `CUSTOM_LLM_PROVIDER_ID` | no | `custom` | Picker group id (becomes `<id>:<model>` prefix). Never `openai`/`anthropic`/`openrouter`/`nvidia`/`fireworks` — boot refuses |
| `FRONTMAN_ALLOWED_ORIGINS` | no | — | Extra socket origins, comma-separated (`//app.example.ts.net`). Omit the port to match any port |
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

What that means in practice:

- **The socket origin allowlist is the only thing standing between a random web
  page and your source tree.** Upstream's `check_origin: false` plus the auth
  bypass let any page open in the same browser connect to
  `http://127.0.0.1:4000` and drive the agent, which writes files in your repo.
  `dev.exs` now allows only `//localhost`, `//127.0.0.1`, `//frontman.local`,
  plus anything in `FRONTMAN_ALLOWED_ORIGINS`. Verified: a foreign `Origin` gets
  **403** on the websocket handshake, allowed ones get **101**. Keep that list as
  small as your setup allows, and never put `false` back while the bypass is on.
- Binding to loopback does not protect against the above (the caller is a page
  in your browser, not a remote host). If you expose the server past loopback
  via a reverse proxy or Tailscale Serve, put authentication on the *proxy* —
  the app has none left.
- The origin check gates the *handshake*, not authorization. An allowed-origin
  connection with no token and no cookie still upgrades (upstream permits an
  anonymous socket); channel joins are what require a scope.

## Merging upstream

All local-mode patches are marked `LOCAL-NOAUTH PATCH`. The philosophy: **keep
the number of touched upstream files small, and inside each one keep the hunks
few, additive, and away from upstream logic.** Concretely:

- Fork-only code lives in **new files** (`providers/custom_llm.ex`,
  `LOCAL-NOAUTH.md`) — a file upstream doesn't have can never conflict.
- A gate is a `case` at the *top* of a function; the upstream body is moved
  verbatim into a `*_original/1` helper. If upstream rewrites that body, git
  applies the change inside the helper with no conflict.
- No upstream function is deleted or reworded (`provider_config/1`,
  `providers.exs`, `user_api_key_controller.ex`, `user_socket.ex` are all
  byte-identical to upstream).

Current merge surface — **10 files for local mode** (hunk counts measured with
`git diff`, i.e. 3 lines of context, which is what a merge actually reasons about):

| File | Hunks | Notes |
|---|---|---|
| `providers.ex` | 5 | alias, prepare path, `max_image_dimension/1`, picker prepend — each a one-liner into `CustomLLM` |
| `user_auth.ex` | 3 | each a `case` + `*_original/1` |
| `config/dev.exs` | 2 | Repo creds; endpoint (http bind + `check_origin`) |
| `user_session_controller.ex` | 2 | `new/2` gate + two private helpers |
| `Makefile` | 2 | drop `op run` |
| `config/runtime.exs` | 1 | one contiguous block appended to the shared section |
| `socket_token_controller.ex` | 1 | whole `show/2` (tiny file) |
| `Client__State__StateReducer.res` | 1 | `hasAnyProviderConfigured` |
| `.gitignore` | 1 | one appended line |
| `envs/.dev.secrets.env` | 1 | file deleted |

Plus `providers/custom_llm.ex` and this file, which are new and cannot conflict.

Two more files — `tool_executor.ex` and `response.ex` — are the upstream bug
fixes described above; they leave the surface if upstream merges the PRs.

To re-check the inventory after a merge:

```bash
git diff --stat <upstream-base> -- . ':!LOCAL-NOAUTH.md'
for f in $(git diff --name-only <upstream-base> -- . ':!LOCAL-NOAUTH.md'); do
  printf "%-62s %s\n" "$f" "$(git diff <upstream-base> -- "$f" | grep -c '^@@')"
done
```

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
