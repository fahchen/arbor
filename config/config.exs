import Config

# Default lifecycle hooks attached to every page server's root socket.
#
# Each entry is `{id, stage, hook_fun}` matching `Arbor.Lifecycle.attach_hook/4`.
#
# Override in an application's own config to disable validation
# (`[]`), replace the validator, or stack additional hooks.

# `:before_command` schema validation runs in every environment so malformed
# payloads crash the runtime per BDR-0003 (let-it-crash) instead of reaching
# user-defined `handle_command/3` clauses with the wrong shape.
command_schema_hook =
  {Arbor.Hooks.ValidateCommandSchema, :before_command,
   &Arbor.Hooks.ValidateCommandSchema.before_command/3}

# Drains pending stream ops from each `Arbor.LiveStream` marked changed and
# prunes the struct. Runs in every environment because the page runtime reads
# the drained accumulator after the resolver returns to build the envelope.
prune_streams_hook =
  {Arbor.Hooks.PruneStreams, :after_serialize, &Arbor.Hooks.PruneStreams.after_serialize/2}

state_validation_hooks =
  if config_env() == :dev do
    [
      {Arbor.Hooks.ValidateToState, :after_serialize,
       &Arbor.Hooks.ValidateToState.after_serialize(:raise, &1, &2)}
    ]
  else
    []
  end

config :arbor,
       :default_hooks,
       [command_schema_hook, prune_streams_hook | state_validation_hooks]

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
