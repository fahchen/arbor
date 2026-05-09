import Config

# Default lifecycle hooks attached to every page server's root socket.
#
# Each entry is `{module, stage}`. `Arbor.Page.Server` derives the hook id from
# the module atom and captures the stage-named callback with the required
# per-stage arity.
#
# Override in an application's own config to disable validation
# (`[]`), replace the validator, or stack additional hooks.
default_hooks =
  if config_env() == :dev do
    [{Arbor.Hooks.ValidateToState, :after_to_state}]
  else
    []
  end

config :arbor, :default_hooks, default_hooks

validate_to_state_mode =
  if config_env() == :prod do
    :telemetry
  else
    :raise
  end

config :arbor, :validate_to_state, validate_to_state_mode
