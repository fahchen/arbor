import Config

# Default lifecycle hooks attached to every page server's root socket.
#
# Each entry is `{id, stage, hook_fun}` matching `Arbor.Lifecycle.attach_hook/4`.
#
# Override in an application's own config to disable validation
# (`[]`), replace the validator, or stack additional hooks.
default_hooks =
  if config_env() == :dev do
    [
      {Arbor.Hooks.ValidateToState, :after_to_state,
       &Arbor.Hooks.ValidateToState.after_to_state(:raise, &1, &2)}
    ]
  else
    []
  end

config :arbor, :default_hooks, default_hooks
