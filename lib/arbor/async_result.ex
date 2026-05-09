defmodule Arbor.AsyncResult do
  @moduledoc "Compile-time async result type marker."

  @type of(value) :: {:loading, value | nil} | {:ok, value} | {:error, term()}
end
