defmodule MyApp.Catalog do
  @moduledoc "Stub catalog that returns canned product rows for the example."

  @sample [
    %{id: "prod_1", name: "Coffee Mug"},
    %{id: "prod_2", name: "Notebook"},
    %{id: "prod_3", name: "Sticker Pack"}
  ]

  @spec list_products() :: [%{id: String.t(), name: String.t()}]
  def list_products, do: @sample

  @spec list_products(map()) :: [%{id: String.t(), name: String.t()}]
  def list_products(%{query: ""}), do: @sample

  def list_products(%{query: query}) when is_binary(query) do
    Enum.filter(@sample, &String.contains?(String.downcase(&1.name), String.downcase(query)))
  end
end
