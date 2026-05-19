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

# Upload-test endpoints. Same pattern: each test module declares its own
# `TestEndpoint` inline and a `PubSub` server, and the keys here track those
# full module names.
for test_mod <- [
      Musubi.Transport.UploadChannelTest,
      Musubi.Transport.UploadConnectionTest,
      Musubi.Upload.ChildStoreTest,
      Musubi.Upload.ExternalModeTest,
      Musubi.Upload.HelpersTest,
      Musubi.Upload.TransportTest,
      Musubi.Upload.WireProtocolTest
    ] do
  config :musubi, Module.concat(test_mod, TestEndpoint),
    pubsub_server: Module.concat(test_mod, PubSub),
    secret_key_base: String.duplicate("a", 64),
    server: false
end
