import Config

# Default lifecycle hooks attached to every page server's root socket.
#
# Each entry is `{id, stage, hook_fun}` matching `Musubi.Lifecycle.attach_hook/4`.
#
# Override in an application's own config to disable validation
# (`[]`), replace the validator, or stack additional hooks.

# `:before_command` schema validation runs in every environment so malformed
# payloads crash the runtime per BDR-0003 (let-it-crash) instead of reaching
# user-defined `handle_command/3` clauses with the wrong shape.
command_schema_hook =
  {Musubi.Hooks.ValidateCommandSchema, :before_command,
   &Musubi.Hooks.ValidateCommandSchema.before_command/3}

# `Musubi.Stream` drain+prune is NOT a hook — it's a runtime invariant baked
# into `Musubi.Resolver.resolve/2` after the `:after_serialize` hooks run.
# Hooks are user-removable; pending stream ops MUST flush every cycle, so the
# prune step lives in the runtime.

state_validation_hooks =
  if config_env() in [:dev, :test] do
    [
      {Musubi.Hooks.ValidateRender, :after_serialize,
       &Musubi.Hooks.ValidateRender.after_serialize(:raise, &1, &2)}
    ]
  else
    []
  end

config :musubi,
       :default_hooks,
       [command_schema_hook | state_validation_hooks]

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
