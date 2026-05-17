defmodule Arbor.Page.StoreTableTest do
  use ExUnit.Case, async: true

  alias Arbor.Page.StoreTable
  alias Arbor.Page.StoreTable.Entry
  alias Arbor.Socket

  defmodule RootStore do
  end

  defmodule FiltersStore do
  end

  defmodule ProductStore do
  end

  test "put/get/delete/keys manage logical store entries by store_id" do
    registry = StoreTable.new()

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
      |> StoreTable.put([], root_entry)
      |> StoreTable.put(["filters"], child_entry)

    assert Enum.sort(StoreTable.keys(registry)) == Enum.sort([[], ["filters"]])

    assert StoreTable.get(registry, []) == root_entry
    assert StoreTable.get(registry, ["filters"]) == child_entry

    registry = StoreTable.delete(registry, ["filters"])
    refute StoreTable.get(registry, ["filters"])
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
      StoreTable.new()
      |> StoreTable.put([], root_entry)
      |> StoreTable.put(["filters"], filters_entry)
      |> StoreTable.put(["filters", "products", "prod_123"], product_entry)

    assert StoreTable.get(registry, []) == root_entry
    assert StoreTable.get(registry, ["filters"]) == filters_entry
    assert StoreTable.get(registry, ["filters", "products", "prod_123"]) == product_entry
    refute StoreTable.get(registry, ["filters", "missing"])
  end
end
