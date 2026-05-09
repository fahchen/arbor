defmodule Arbor.DSL.AttrTest do
  use ExUnit.Case, async: true

  alias Arbor.DSL.Attr

  defmodule AttrFixture do
    use Arbor.Store

    attr(:current_user, String.t(), required: true)
    attr(:selected, boolean(), default: false)
    attr(:on_select, (%{id: String.t()} -> any()), required: true)
  end

  test "attr metadata is exposed through __arbor__(:attrs)" do
    assert [
             %{name: :current_user, type: current_user_type, required: true, default: no_default},
             %{name: :selected, type: selected_type, required: false, default: false},
             %{name: :on_select, type: callback_type, required: true, default: no_default_again}
           ] = AttrFixture.__arbor__(:attrs)

    assert no_default == Attr.no_default()
    assert no_default_again == Attr.no_default()
    assert Macro.to_string(current_user_type) == "String.t()"
    assert Macro.to_string(selected_type) == "boolean()"
    assert Macro.to_string(callback_type) == "(%{id: String.t()} -> any())"
  end
end
