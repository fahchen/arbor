defmodule Arbor.StoreRegistryTest do
  use ExUnit.Case, async: true

  alias Arbor.Socket
  alias Arbor.StoreRegistry
  alias Arbor.StoreRegistry.Entry

  defmodule RootStore do
  end

  defmodule FiltersStore do
  end

  defmodule ProductStore do
  end

  test "put/get/delete/keys manage logical store entries by identity" do
    registry = StoreRegistry.new()

    root_entry = %Entry{
      socket: %Socket{id: "", parent_path: [], module: RootStore, assigns: %{}, private: %{}},
      module: RootStore
    }

    child_entry = %Entry{
      socket: %Socket{
        id: "filters",
        parent_path: [],
        module: FiltersStore,
        assigns: %{},
        private: %{}
      },
      module: FiltersStore
    }

    registry =
      registry
      |> StoreRegistry.put([], RootStore, "", root_entry)
      |> StoreRegistry.put([], FiltersStore, "filters", child_entry)

    assert Enum.sort(StoreRegistry.keys(registry)) ==
             Enum.sort([{[], RootStore, ""}, {[], FiltersStore, "filters"}])

    assert StoreRegistry.get(registry, [], RootStore, "") == root_entry
    assert StoreRegistry.get(registry, [], FiltersStore, "filters") == child_entry

    registry = StoreRegistry.delete(registry, [], FiltersStore, "filters")
    refute StoreRegistry.get(registry, [], FiltersStore, "filters")
  end

  test "path_lookup resolves root and nested child paths" do
    root_entry = %Entry{
      socket: %Socket{id: "", parent_path: [], module: RootStore, assigns: %{}, private: %{}},
      module: RootStore
    }

    filters_entry = %Entry{
      socket: %Socket{
        id: "filters",
        parent_path: [],
        module: FiltersStore,
        assigns: %{},
        private: %{}
      },
      module: FiltersStore
    }

    product_entry = %Entry{
      socket: %Socket{
        id: "prod_123",
        parent_path: ["filters", "products"],
        module: ProductStore,
        assigns: %{},
        private: %{}
      },
      module: ProductStore
    }

    registry =
      StoreRegistry.new()
      |> StoreRegistry.put([], RootStore, "", root_entry)
      |> StoreRegistry.put([], FiltersStore, "filters", filters_entry)
      |> StoreRegistry.put(["filters", "products"], ProductStore, "prod_123", product_entry)

    assert StoreRegistry.path_lookup(registry, []) == root_entry
    assert StoreRegistry.path_lookup(registry, ["filters"]) == filters_entry

    assert StoreRegistry.path_lookup(registry, ["filters", "products", "prod_123"]) ==
             product_entry

    refute StoreRegistry.path_lookup(registry, ["filters", "missing"])
  end
end
