defmodule MyApp.Persistence do
  @moduledoc """
  In-memory ETS-backed cart snapshot store. Models the
  `docs/persistence-pattern.md` recommendation: load inside `mount/1`,
  then keep mounted pages synchronized through application-owned PubSub.
  """

  use GenServer

  @table :cart_page_persistence
  @pubsub MyApp.PubSub
  @topic_prefix "cart:"

  @typep cart_id() :: String.t()
  @typep cart_line() :: %{
           required(:id) => String.t(),
           required(:sku) => String.t(),
           required(:name) => String.t(),
           required(:price_cents) => integer(),
           required(:qty) => integer()
         }
  @typep update_fun() :: ([cart_line()] -> [cart_line()])
  @typep state() :: %{}

  @doc """
  Starts the in-memory cart persistence process.

  ## Examples

      MyApp.Persistence.start_link([])
      #=> {:ok, pid}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Subscribes the calling page process to cart snapshot broadcasts.

  ## Examples

      MyApp.Persistence.subscribe_cart("demo-cart")
      #=> :ok
  """
  @spec subscribe_cart(cart_id()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe_cart(cart_id) when is_binary(cart_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(cart_id))
  end

  @doc """
  Returns the saved cart lines for `cart_id`, or an empty list when
  nothing has been saved yet.

  ## Examples

      MyApp.Persistence.load_cart("demo-cart")
      #=> []
  """
  @spec load_cart(cart_id()) :: [cart_line()]
  def load_cart(cart_id) when is_binary(cart_id) do
    case :ets.lookup(@table, cart_id) do
      [{^cart_id, lines}] -> lines
      [] -> []
    end
  end

  @doc """
  Atomically updates the saved cart lines and broadcasts the new snapshot.

  The update function receives the latest storage snapshot, not the caller's
  potentially stale page-local assigns.

  ## Examples

      lines = MyApp.Persistence.update_cart("demo-cart", fn lines -> lines end)
      #=> []
  """
  @spec update_cart(cart_id(), update_fun()) :: [cart_line()]
  def update_cart(cart_id, fun) when is_binary(cart_id) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:update_cart, cart_id, fun})
  end

  @doc """
  Persists `lines` under `cart_id`, overwrites any existing snapshot, and
  broadcasts the new snapshot.

  ## Examples

      MyApp.Persistence.save_cart("demo-cart", [])
      #=> :ok
  """
  @spec save_cart(cart_id(), [cart_line()]) :: :ok
  def save_cart(cart_id, lines) when is_binary(cart_id) and is_list(lines) do
    GenServer.call(__MODULE__, {:save_cart, cart_id, lines})
  end

  @impl GenServer
  @spec init(:ok) :: {:ok, state()}
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:update_cart, cart_id, fun}, _from, state) do
    lines = load_cart(cart_id)
    next_lines = validate_lines!(fun.(lines))
    write_cart!(cart_id, next_lines)
    broadcast_cart(cart_id, next_lines)
    {:reply, next_lines, state}
  end

  def handle_call({:save_cart, cart_id, lines}, _from, state) do
    next_lines = validate_lines!(lines)
    write_cart!(cart_id, next_lines)
    broadcast_cart(cart_id, next_lines)
    {:reply, :ok, state}
  end

  defp validate_lines!(lines) when is_list(lines), do: lines

  defp validate_lines!(other) do
    raise ArgumentError, "cart persistence update must return a list, got: #{inspect(other)}"
  end

  defp write_cart!(cart_id, lines) do
    :ets.insert(@table, {cart_id, lines})
    :ok
  end

  defp broadcast_cart(cart_id, lines) do
    Phoenix.PubSub.broadcast(@pubsub, topic(cart_id), {:cart_snapshot, cart_id, lines})
  end

  defp topic(cart_id), do: @topic_prefix <> cart_id
end
