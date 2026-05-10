import Config

# Test-only TS codegen output path. The integration test for
# `Mix.Tasks.Compile.ArborTs` (`test/mix/tasks/compile/arbor_ts_test.exs`)
# drives the compiler end-to-end against this path. Tests own cleanup.
config :arbor, :ts_codegen_output_path, "test/tmp/arbor_ts_bundle.ts"

# Test-only endpoint config for the Phoenix Channel adapter test
# (`test/arbor/transport/channel_test.exs`). The endpoint is defined inside the
# test module so the keys here track that module's full name. `server: false`
# keeps the endpoint from binding any port.
config :arbor, Arbor.Transport.ChannelTest.TestEndpoint,
  pubsub_server: Arbor.Transport.ChannelTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false
