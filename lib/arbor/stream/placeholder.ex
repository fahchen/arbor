defmodule Arbor.Stream.Placeholder do
  @moduledoc false

  use TypedStructor

  typed_structor do
    field :name, Arbor.Stream.stream_name(),
      enforce: true,
      doc: "Declared stream name placed by `stream(:name)` inside render output."
  end
end
