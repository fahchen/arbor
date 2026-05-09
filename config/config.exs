import Config

# Default lifecycle hooks attached to every page server's root socket.
#
# Each entry is `{id, stage, hook_fun}` matching the
# `Arbor.Lifecycle.attach_hook/4` argument order. The hook function is the
# capture passed straight into `attach_hook` — usually `&Module.fun/2`.
#
# Override in an application's own config to disable validation
# (`[]`), replace the validator, or stack additional hooks.
config :arbor, :default_hooks, [
  {Arbor.Hooks.ValidateToState, :after_to_state, &Arbor.Hooks.ValidateToState.run/2}
]
