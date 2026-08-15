import Config

config :frontman_server,
  env: :dev,
  llm_wire_tap_enabled: true

# LOCAL-NOAUTH PATCH: DB connection from env with upstream defaults, so a
# stock local Postgres works out of the box and custom deployments (custom
# port/user) just set vars. Read via System.get_env (systemd EnvironmentFile
# exports these before the beam starts; runtime.exs re-reads are unaffected).
config :frontman_server, FrontmanServer.Repo,
  username: System.get_env("DB_USERNAME") || "postgres",
  password: System.get_env("DB_PASSWORD") || "postgres",
  hostname: System.get_env("DB_HOST") || "localhost",
  port: String.to_integer(System.get_env("DB_PORT") || "5432"),
  database: System.get_env("DB_NAME") || "frontman_server_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :frontman_server, FrontmanServerWeb.Endpoint,
  url: [
    host: System.get_env("PHX_HOST") || "frontman.local",
    port: String.to_integer(System.get_env("PHX_URL_PORT") || "4000"),
    scheme: "https"
  ],
  # LOCAL-NOAUTH PATCH: plain HTTP on loopback behind a TLS-terminating
  # reverse proxy (Caddy/nginx/Tailscale Serve). Client-side https:// URLs
  # are satisfied by the cert on the proxy front; $PORT (default 4000) lets
  # multiple local services coexist on one host.
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("PORT") || "4000")
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "NBTbU2SqLo+ghhs3jQiZAjRrQKhim/x/HXSbx49mBnt4pSvEkjTYYrj+prSCInNO",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:frontman_server, ~w(--sourcemap=inline --watch)]},
    esbuild: {Esbuild, :install_and_run, [:browser_test, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:frontman_server, ~w(--watch)]}
  ]

config :frontman_server, FrontmanServerWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/frontman_server_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$"
    ]
  ]

config :frontman_server, dev_routes: true

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :logger, level: :info

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :req_llm,
  telemetry: [payloads: :raw],
  debug: true

config :swoosh, :api_client, false

config :frontman_server, FrontmanServer.Mailer, api_key: "re_dev_placeholder"
