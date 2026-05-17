import Config

config :phoenix, :json_library, Jason

config :musubi, :ts_codegen_output_path, "ui/src/generated/musubi.d.ts"

config :poll_app, PollAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  pubsub_server: PollApp.PubSub,
  secret_key_base: "poll_app_secret_key_base_for_example_only_0123456789abcdef",
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4003]

if config_env() == :dev do
  import_config "dev.exs"
end
