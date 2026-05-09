defmodule Arbor.TestSupport.TypespecProbeChild do
  @moduledoc false

  use Arbor.State

  state do
    field :amount, integer()
  end
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
end
