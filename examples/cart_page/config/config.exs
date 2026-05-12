import Config

config :phoenix, :json_library, Jason

config :arbor, :ts_codegen_output_path, "ui/src/generated/arbor.d.ts"

config :cart_page, MyAppWeb.Endpoint,
  url: [host: "localhost"],
  pubsub_server: MyApp.PubSub,
  secret_key_base: "cart_page_secret_key_base_for_example_only_0123456789abcdef",
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4001]

if config_env() == :dev do
  import_config "dev.exs"
end
