defmodule Arbor.Async.MacrosTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "compile-time socket-capture warning" do
    test "warns when assign_async closes over `socket` via fn" do
      stderr =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule Arbor.Async.MacrosTest.AssignFnCapture do
            use Arbor.Store

            state do
              field :user, String.t()
            end

            def mount(socket), do: {:ok, socket}
            def render(socket), do: %{user: socket.assigns.user}
            def handle_command(_name, _payload, socket), do: {:noreply, socket}

            def fetch(socket) do
              assign_async(socket, :user, fn -> {:ok, socket.assigns.user} end)
            end
          end
          """)
        end)

      assert stderr =~ "assign_async/3,4: the task fn captures `socket`"
    end

    test "warns when start_async closes over `socket` via & capture" do
      stderr =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule Arbor.Async.MacrosTest.StartCaptureCapture do
            use Arbor.Store

            state do
              field :ok, boolean()
            end

            def mount(socket), do: {:ok, socket}
            def render(_socket), do: %{ok: true}
            def handle_command(_name, _payload, socket), do: {:noreply, socket}

            def warm(socket) do
              start_async(socket, :warm, &touch(socket, &1))
            end

            defp touch(_socket, _x), do: :ok
          end
          """)
        end)

      assert stderr =~ "start_async/3,4: the task fn captures `socket`"
    end

    test "does not warn when fn closes over locals only" do
      stderr =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule Arbor.Async.MacrosTest.AssignNoCapture do
            use Arbor.Store

            state do
              field :user, String.t()
            end

            def mount(socket), do: {:ok, socket}
            def render(socket), do: %{user: socket.assigns.user}
            def handle_command(_name, _payload, socket), do: {:noreply, socket}

            def fetch(socket) do
              user_id = socket.assigns[:user_id]
              assign_async(socket, :user, fn -> {:ok, user_id} end)
            end
          end
          """)
        end)

      refute stderr =~ "captures `socket`"
    end

    test "does not warn when the task fn is built by a helper that takes socket" do
      stderr =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule Arbor.Async.MacrosTest.HelperFnNoCapture do
            use Arbor.Store

            state do
              field :user, String.t()
            end

            def mount(socket), do: {:ok, socket}
            def render(socket), do: %{user: socket.assigns.user}
            def handle_command(_name, _payload, socket), do: {:noreply, socket}

            def fetch(socket) do
              start_async(socket, :user, build_fun(socket))
            end

            defp build_fun(_socket), do: fn -> :ok end
          end
          """)
        end)

      refute stderr =~ "captures `socket`"
    end
  end
end
