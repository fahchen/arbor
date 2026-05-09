# STUB ONLY — final implementation in Track B; merge will replace this.
defmodule Arbor.Socket do
  @moduledoc "STUB — replaced by Track B at merge."

  @enforce_keys [:id, :parent_path, :module]
  defstruct assigns: %{},
            id: "",
            parent_path: [],
            module: nil,
            endpoint: nil,
            topic: nil,
            transport_pid: nil,
            private: %{}

  @type t :: %__MODULE__{
          assigns: map(),
          id: String.t(),
          parent_path: [atom() | String.t()],
          module: module(),
          endpoint: term(),
          topic: term(),
          transport_pid: pid() | nil,
          private: map()
        }
end
