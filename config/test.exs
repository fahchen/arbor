import Config

# Test-only endpoint config for the Phoenix Channel adapter test
# (`test/arbor/transport/channel_test.exs`). The endpoint is defined inside the
# test module so the keys here track that module's full name. `server: false`
# keeps the endpoint from binding any port.
config :arbor, Arbor.Transport.ChannelTest.TestEndpoint,
  pubsub_server: Arbor.Transport.ChannelTest.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: false
