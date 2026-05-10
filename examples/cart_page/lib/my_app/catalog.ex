defmodule MyApp.Catalog do
  @moduledoc "Stub product catalog returning canned SKUs for the cart example."

  @products %{
    "mug" => %{sku: "mug", name: "Coffee Mug", price_cents: 1_500},
    "notebook" => %{sku: "notebook", name: "Notebook", price_cents: 800},
    "stickers" => %{sku: "stickers", name: "Sticker Pack", price_cents: 500}
  }

  @doc "Returns `{:ok, product}` when `sku` exists, `:error` otherwise."
  @spec fetch(String.t()) ::
          {:ok, %{sku: String.t(), name: String.t(), price_cents: integer()}} | :error
  def fetch(sku) when is_binary(sku) do
    case Map.fetch(@products, sku) do
      {:ok, _product} = ok -> ok
      :error -> :error
    end
  end
end
