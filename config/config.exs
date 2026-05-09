import Config

# Default lifecycle hooks attached to every page server's root socket.
#
# Each entry is `{module, stage}`. `Arbor.Page.Server` derives the hook id from
# the module atom and captures the stage-named callback with the required
# per-stage arity.
#
# Override in an application's own config to disable validation
# (`[]`), replace the validator, or stack additional hooks.
config :arbor, :default_hooks, [
  {Arbor.Hooks.ValidateToState, :after_to_state}
]
