defmodule Arbor.LifecycleTest do
  use ExUnit.Case, async: true

  alias Arbor.Lifecycle
  alias Arbor.Socket

  defmodule RootStore do
  end

  setup do
    socket = %Socket{id: "", parent_path: [], module: RootStore, assigns: %{}, private: %{}}
    %{socket: socket}
  end

  test "attach_hook registers hooks across all supported stages", %{socket: socket} do
    hooked_socket =
      Enum.reduce(Lifecycle.stages(), socket, fn stage, acc ->
        Lifecycle.attach_hook(acc, {:id, stage}, stage, fn _ctx, current_socket ->
          {:cont, current_socket}
        end)
      end)

    hooks = hooked_socket.private[:hooks]

    assert Enum.sort(Map.keys(hooks)) == Enum.sort(Lifecycle.stages())

    Enum.each(Lifecycle.stages(), fn stage ->
      assert [%{id: {:id, ^stage}}] = hooks[stage]
    end)
  end

  test "attach_hook preserves attachment order", %{socket: socket} do
    socket =
      socket
      |> Lifecycle.attach_hook(:first, :before_command, fn _ctx, current_socket ->
        {:cont, current_socket}
      end)
      |> Lifecycle.attach_hook(:second, :before_command, fn _ctx, current_socket ->
        {:cont, current_socket}
      end)

    assert [%{id: :first}, %{id: :second}] = socket.private[:hooks][:before_command]
  end

  test "re-attaching the same id on the same stage raises", %{socket: socket} do
    socket =
      Lifecycle.attach_hook(socket, :audit, :before_command, fn _ctx, current_socket ->
        {:cont, current_socket}
      end)

    assert_raise ArgumentError, ~r/hook :audit already attached/, fn ->
      Lifecycle.attach_hook(socket, :audit, :before_command, fn _ctx, current_socket ->
        {:cont, current_socket}
      end)
    end
  end

  test "detach_hook silently no-ops when absent", %{socket: socket} do
    assert Lifecycle.detach_hook(socket, :missing, :before_command) == socket
  end

  test "run_hooks iterates in order and returns the final socket", %{socket: socket} do
    socket =
      socket
      |> Lifecycle.attach_hook(:first, :before_command, fn ctx, current_socket ->
        {:cont,
         put_in(current_socket.assigns[:order], [ctx | current_socket.assigns[:order] || []])}
      end)
      |> Lifecycle.attach_hook(:second, :before_command, fn _ctx, current_socket ->
        order = Enum.reverse(current_socket.assigns.order)
        next_order = Enum.reverse([:second | Enum.reverse(order)])
        {:cont, put_in(current_socket.assigns[:order], next_order)}
      end)

    assert {:cont, final_socket} = Lifecycle.run_hooks(socket, :before_command, :first, false)
    assert final_socket.assigns.order == [:first, :second]
  end

  test "run_hooks short-circuits on {:halt, socket}", %{socket: socket} do
    socket =
      socket
      |> Lifecycle.attach_hook(:halting, :before_command, fn _ctx, current_socket ->
        {:halt, put_in(current_socket.assigns[:halted], true)}
      end)
      |> Lifecycle.attach_hook(:later, :before_command, fn _ctx, current_socket ->
        {:cont, put_in(current_socket.assigns[:later], true)}
      end)

    assert {:halt, final_socket} = Lifecycle.run_hooks(socket, :before_command, :ctx, false)
    assert final_socket.assigns.halted
    refute Map.has_key?(final_socket.assigns, :later)
  end

  test "run_hooks returns {:halt, reply, socket} when halt payloads are allowed", %{
    socket: socket
  } do
    socket =
      Lifecycle.attach_hook(socket, :replying, :before_command, fn _ctx, current_socket ->
        {:halt, %{ok: false}, current_socket}
      end)

    assert {:halt, %{ok: false}, ^socket} =
             Lifecycle.run_hooks(socket, :before_command, :ctx, true)
  end

  test "run_hooks raises when a halt payload is returned but not allowed", %{socket: socket} do
    socket =
      Lifecycle.attach_hook(socket, :replying, :after_command, fn _ctx, current_socket ->
        {:halt, %{ok: false}, current_socket}
      end)

    assert_raise ArgumentError, ~r/halt payloads are only allowed/, fn ->
      Lifecycle.run_hooks(socket, :after_command, :ctx, false)
    end
  end
end
