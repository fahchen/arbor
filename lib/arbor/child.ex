defmodule Arbor.Child do
  @moduledoc "Render-time child placeholder sentinel resolved by `Arbor.Resolver` when it appears in store output."

  use TypedStructor

  @type assigns_map() :: map()

  typed_structor do
    field(:module, module(), enforce: true)
    field(:id, String.t() | nil, default: nil)
    field(:assigns, assigns_map(), default: %{})
  end

  @doc """
  Builds a child placeholder sentinel.

  The runtime treats the returned struct specially only when it appears inside a
  `to_state/1` return value. Elsewhere it is inert data.

  ## Examples

      iex> sentinel = Arbor.Child.child(MyStore, id: "sidebar", title: "Inbox")
      iex> sentinel.module
      MyStore
      iex> sentinel.id
      "sidebar"
      iex> sentinel.assigns
      %{title: "Inbox"}
  """
  @spec child(module(), keyword()) :: t()
  def child(module, opts \\ []) when is_atom(module) and is_list(opts) do
    {id, assigns_opts} = Keyword.pop(opts, :id)

    %__MODULE__{
      module: module,
      id: id,
      assigns: Map.new(assigns_opts)
    }
  end
end
