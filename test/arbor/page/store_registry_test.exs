defmodule Arbor.Page.StoreRegistryTest do
  use ExUnit.Case, async: true

  alias Arbor.Page.StoreRegistry
  alias Arbor.Page.StoreRegistry.Entry
  alias Arbor.Socket

  defmodule RootStore do
  end

  defmodule FiltersStore do
  end

  defmodule ProductStore do
  end

  test "put/get/delete/keys manage logical store entries by store_id" do
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
      |> StoreRegistry.put([], root_entry)
      |> StoreRegistry.put(["filters"], child_entry)

    assert Enum.sort(StoreRegistry.keys(registry)) == Enum.sort([[], ["filters"]])

    assert StoreRegistry.get(registry, []) == root_entry
    assert StoreRegistry.get(registry, ["filters"]) == child_entry

    registry = StoreRegistry.delete(registry, ["filters"])
    refute StoreRegistry.get(registry, ["filters"])
  end

  test "get/2 resolves root and nested store_ids directly (no scan)" do
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
      |> StoreRegistry.put([], root_entry)
      |> StoreRegistry.put(["filters"], filters_entry)
      |> StoreRegistry.put(["filters", "products", "prod_123"], product_entry)

    assert StoreRegistry.get(registry, []) == root_entry
    assert StoreRegistry.get(registry, ["filters"]) == filters_entry
    assert StoreRegistry.get(registry, ["filters", "products", "prod_123"]) == product_entry
    refute StoreRegistry.get(registry, ["filters", "missing"])
  end
end
