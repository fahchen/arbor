import Config

# Test-only TS codegen output path. The integration test for
# `Mix.Tasks.Compile.MusubiTs` (`test/mix/tasks/compile/musubi_ts_test.exs`)
# drives the compiler end-to-end against this path. Tests own cleanup.
config :musubi, :ts_codegen_output_path, "test/tmp/musubi_ts_bundle.ts"

# Test-only endpoint config for the Phoenix Channel adapter test
# (`test/musubi/transport/channel_test.exs`). The endpoint is defined inside the
# test module so the keys here track that module's full name. `server: false`
# keeps the endpoint from binding any port.
config :musubi, Musubi.Transport.ChannelTest.TestEndpoint,
  pubsub_server: Musubi.Transport.ChannelTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false

config :musubi, Musubi.Transport.ConnectionChannelTest.TestEndpoint,
  pubsub_server: Musubi.Transport.ConnectionChannelTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false

# Upload-test endpoints. Each test module declares its own `TestEndpoint`
# inline and a sibling `PubSub` server, so the keys here track those full
# module names. One stanza per test module.

config :musubi, Musubi.Transport.UploadChannelTest.TestEndpoint,
  pubsub_server: Musubi.Transport.UploadChannelTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false

config :musubi, Musubi.Transport.UploadConnectionTest.TestEndpoint,
  pubsub_server: Musubi.Transport.UploadConnectionTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false

config :musubi, Musubi.Upload.ChildStoreTest.TestEndpoint,
  pubsub_server: Musubi.Upload.ChildStoreTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false

config :musubi, Musubi.Upload.ExternalModeTest.TestEndpoint,
  pubsub_server: Musubi.Upload.ExternalModeTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false

config :musubi, Musubi.Upload.HelpersTest.TestEndpoint,
  pubsub_server: Musubi.Upload.HelpersTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false

config :musubi, Musubi.Upload.TransportTest.TestEndpoint,
  pubsub_server: Musubi.Upload.TransportTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false

config :musubi, Musubi.Upload.WireProtocolTest.TestEndpoint,
  pubsub_server: Musubi.Upload.WireProtocolTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false
