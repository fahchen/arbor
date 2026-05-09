defmodule Arbor.TestSupport.TypespecProbe do
  @moduledoc false

  use Arbor.Store

  state do
    stream(:messages, String.t())
  end
end
