import Config

alias Ecto.Adapters.SQL.Sandbox

# Fast Argon2 hashing for tests
config :argon2_elixir, t_cost: 1, m_cost: 8

# In test we don't send emails
config :liteskill, Liteskill.Mailer, adapter: Swoosh.Adapters.Test

config :liteskill, Liteskill.Rag.EmbedQueue,
  max_retries: 1,
  backoff_ms: 1,
  flush_ms: 50

config :liteskill, Liteskill.Repo,
  database: Path.expand("../priv/liteskill_test#{System.get_env("MIX_TEST_PARTITION", "")}.db", __DIR__),
  foreign_keys: :on,
  journal_mode: :wal,
  busy_timeout: 15_000,
  pool: Sandbox,
  # SQLite supports only one writer at a time. A single pool connection avoids
  # "Database busy" errors from multiple connections contending for the write lock.
  pool_size: 1

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :liteskill, LiteskillWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "k7UgpXGIuGs58stVlRNPYmIA3Rq1+0geRNZ5XaiFSVCLqkZdWXbXcQhf71wg5U5U",
  server: true

config :liteskill, Oban, testing: :manual

# Ecto sandbox for Wallaby browser tests
config :liteskill, :sandbox, Sandbox

# Disable persistent_term cache for Settings (incompatible with Ecto sandbox)
config :liteskill, :settings_cache, false

# Tests run in multi-user mode by default; individual tests use Application.put_env to test single-user mode
config :liteskill, :single_user_mode, false

# Used by Application to skip ensure_admin_user Task (sandbox not available)
config :liteskill, env: :test

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Wallaby E2E browser testing
# CI: run Chrome headless with sandbox disabled (containerized environment)
config :wallaby,
  driver: Wallaby.Chrome,
  otp_app: :liteskill,
  screenshot_on_failure: true,
  screenshot_dir: "tmp/wallaby_screenshots",
  js_errors: false,
  max_wait_time: 15_000

if System.get_env("CI") do
  config :wallaby,
    chromedriver: [
      capabilities: %{
        chromeOptions: %{
          args: [
            "--no-sandbox",
            "--headless",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--fullscreen",
            "window-size=1280,800",
            "--user-agent=Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"
          ]
        },
        javascriptEnabled: false,
        loadImages: false,
        unhandledPromptBehavior: "accept",
        loggingPrefs: %{browser: "DEBUG"}
      }
    ]
end
