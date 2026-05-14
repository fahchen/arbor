defmodule Arbor.Stream.AsyncPlaceholder do
  @moduledoc false

  use TypedStructor

  typed_structor do
    field :name, Arbor.Stream.stream_name(),
      enforce: true,
      doc: "Declared async stream name placed by `async_stream(:name)` inside render output."
  end
end
