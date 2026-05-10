defmodule Arbor.TestSupport.TypespecProbeChild do
  @moduledoc false

  use Arbor.State

  state do
    field :amount, integer()
  end

  # Snapshot the compile-time env (alias scope, module name, file) so codegen
  # tests can drive `Arbor.Codegen.TypeScript.Manifest.collect/1` against the
  # same env the `:arbor_ts` compiler would see at consumer compile time.
  @captured_env __ENV__
  @doc false
  def __env__, do: @captured_env
end

defmodule Arbor.TestSupport.TypespecProbe do
  @moduledoc false

  use Arbor.Store

  alias Arbor.TestSupport.TypespecProbeChild

  state do
    stream(:messages, String.t())
    stream(:items, TypespecProbeChild.t(), item_key: &"item-#{&1.amount}", limit: -50)
    field :load_stream, Arbor.AsyncResult.of(stream(TypespecProbeChild.t()))
    field :profile, Arbor.AsyncResult.of(TypespecProbeChild.t())
    field :status, %{type: :active} | %{type: :paused, value: integer()}
    field :child, TypespecProbeChild.state()
    field :tags, list(String.t())
  end

  @captured_env __ENV__
  @doc false
  def __env__, do: @captured_env
end

defmodule Arbor.TestSupport.TypespecProbeWithCommand do
  @moduledoc false

  use Arbor.Store

  state do
    field :selected_id, String.t() | nil
  end

  command :select do
    payload :id, String.t()
  end

  command :refresh

  @captured_env __ENV__
  @doc false
  def __env__, do: @captured_env
end
