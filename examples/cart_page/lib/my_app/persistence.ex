defmodule MyApp.Persistence do
  @moduledoc """
  In-memory ETS-backed cart snapshot store. Models the
  `docs/persistence-pattern.md` recommendation: load inside `mount/1`,
  save via `attach_hook(:persist, :after_command, fun)`.
  """

  use GenServer

  @table :cart_page_persistence

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Returns the saved cart lines for `cart_id`, or an empty list when
  nothing has been saved yet.
  """
  @spec load_cart(String.t()) :: [map()]
  def load_cart(cart_id) when is_binary(cart_id) do
    case :ets.lookup(@table, cart_id) do
      [{^cart_id, lines}] -> lines
      [] -> []
    end
  end

  @doc "Persists `lines` under `cart_id`. Overwrites any existing snapshot."
  @spec save_cart(String.t(), [map()]) :: :ok
  def save_cart(cart_id, lines) when is_binary(cart_id) and is_list(lines) do
    :ets.insert(@table, {cart_id, lines})
    :ok
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
