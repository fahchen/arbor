defmodule Arbor.TestSupport.TypespecProbe do
  @moduledoc false

  use Arbor.Store

  state do
    field(:messages, stream(String.t()))
  end
end
