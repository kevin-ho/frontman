# LOCAL-NOAUTH mode

Run the Frontman server with WorkOS auth bypassed (single local user) and any
OpenAI-compatible LLM endpoint (LiteLLM, Mistral, Google AI Studio
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
4. **Client provider-setup gate — solved server-side, no client patch.**
   The compiled client decides "is any provider configured?" purely from
   `/api/user/api-keys`, and recognises only its four hardcoded cloud providers.
   With a `CUSTOM_LLM_*` provider it would park on the setup screen forever, so
   `user_api_key_controller.ex` adds an `"openrouter"` marker to that response
   (logic in the fork-only `frontman_server_web/local_noauth.ex`).
   - Applied at the **controller** boundary, never inside
     `Providers.list_api_key_providers/1` — the model picker calls that function
     directly, so it never advertises cloud models this install can't use.
     Verified: `/api/user/api-keys` → `{"providers":["openrouter"]}` while the
     picker shows only the custom group.
   - **`Client__State__StateReducer.res` is upstream-identical**, so the stock
     client bundle works and **no client rebuild is needed after an upstream
     merge**. That file is the highest-churn file in the repo (50 of the last 200
     upstream commits), which is exactly why the fix does not live there.
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

## Example: local OpenAI-compatible gateway

```bash
CUSTOM_LLM_PROVIDER_ID=custom
CUSTOM_LLM_DISPLAY_NAME=Local Gateway
CUSTOM_LLM_BASE_URL=http://127.0.0.1:4000/v1
CUSTOM_LLM_API_KEY=...
CUSTOM_LLM_MODELS=Main|my-main-combo
```

Restart the service after changing any of these — they're read at boot.

## First-run seeding

The DB needs the local user, and nothing else. **No API-key rows are needed** —
the `"openrouter"` marker on `/api/user/api-keys` (item 4 above) opens the
provider-setup gate.

One older recipe is retired and should not be reintroduced: seeding a decoy
`openrouter` API-key row in the database. It polluted the model picker with 22
cloud models that could never work here, because the picker reads the same table.
The marker is applied at the controller instead, which the picker never consults.

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

Current merge surface — **10 files for local mode, none of them in the client** (hunk counts measured with
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
| `user_api_key_controller.ex` | 1 | gate marker (upstream touches it 4/200) |
| `.gitignore` | 1 | one appended line |
| `envs/.dev.secrets.env` | 1 | file deleted |

Plus `providers/custom_llm.ex`, `frontman_server_web/local_noauth.ex` and this
file, which are new and cannot conflict.

Two more files — `tool_executor.ex` and `response.ex` — are the upstream bug
fixes described above; they leave the surface if upstream merges the PRs.

### Upstream churn per patched file

How often upstream touches each file we patch (last 200 upstream commits) — this
is the real conflict-probability ranking, so weigh it before adding a patch:

| File | Touched by | |
|---|---|---|
| `Client__State__StateReducer.res` | 50 / 200 | hottest file in the repo — deliberately NOT patched |
| `providers.ex` | 20 / 200 | |
| `config/runtime.exs` | 17 / 200 | our hunk is at the end, away from the churn |
| `user_auth.ex` | 11 / 200 | |
| `config/dev.exs` | 10 / 200 | |
| `user_session_controller.ex` | 7 / 200 | |
| `Makefile` | 6 / 200 | |
| `user_api_key_controller.ex` | 4 / 200 | carries the gate marker instead |
| `socket_token_controller.ex` | 2 / 200 | |

### `make check-source-comments` fails here by design

Upstream CI enforces comment-free authored source (`scripts/no-comments.mjs`,
added in #1361). This fork carries ~70 `# LOCAL-NOAUTH PATCH` comments on
purpose — they are the map of what we changed. Don't chase that target green on
this branch.

It does mean **anything sent upstream must be comment-free**: the
`upstream-fixes` branch is, and passes `make check-source-comments`. Rationale for
those commits lives in the commit messages, not in the source.

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

**No longer required.** The fork carries **zero client patches** — the provider
gate is handled server-side (item 4 above) — so upstream's own bundle works,
whether from the CDN or a local build. Nothing here needs redoing after an
upstream merge.

Build from source only if you want to change the overlay UI yourself:

```bash
corepack enable --install-directory ~/.local/bin   # once; yarn 4 via corepack
cd <repo>
yarn install                                        # full monorepo workspace
make -C libs/client build-standalone                # rescript build + vite bundle
cp libs/client/dist/frontman.es.js <app>/public/frontman/
cp libs/client/dist/frontman.css   <app>/public/frontman/
```

Output is a single self-contained ES module (`dist/frontman.es.js`, ~2.6 MB,
React bundled) plus `frontman.css`. Since the fork carries no client patches, a
build from this repo should match upstream's CDN bundle — that equivalence is the
sanity check that the pipeline is faithful.
