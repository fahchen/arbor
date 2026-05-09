defmodule Arbor.Async.Macros do
  @moduledoc """
  Compile-time wrappers for `Arbor.Async`'s task-spawning entry points.

  Imported by `Arbor.Store.__using__/1` so a store can write
  `assign_async(socket, :foo, fn -> fetch() end)` and trigger the
  socket-capture lint at compile time. Calls resolve to
  `Arbor.Async.assign_async/3,4` etc. at runtime.

  ## Socket-capture warning

  Mirrors `Phoenix.LiveView`'s warning. Closing over `socket` inside the
  task fun risks data races: the task runs concurrently with the next
  handler, so the captured `socket` is a frozen snapshot whose `assigns`
  may already be stale. Recommended fix: bind the values you need to
  local variables before the fn.

      # Bad — captures socket
      assign_async(socket, :profile, fn -> fetch(socket.assigns.user_id) end)

      # Good — explicit local binding
      user_id = socket.assigns.user_id
      assign_async(socket, :profile, fn -> fetch(user_id) end)
  """

  alias Arbor.Async

  @doc "See `Arbor.Async.assign_async/3,4`."
  defmacro assign_async(socket, key_or_keys, fun) do
    warn_on_socket_capture!(fun, :assign_async, __CALLER__)

    quote do
      Async.assign_async(unquote(socket), unquote(key_or_keys), unquote(fun))
    end
  end

  defmacro assign_async(socket, key_or_keys, fun, opts) do
    warn_on_socket_capture!(fun, :assign_async, __CALLER__)

    quote do
      Async.assign_async(unquote(socket), unquote(key_or_keys), unquote(fun), unquote(opts))
    end
  end

  @doc "See `Arbor.Async.start_async/3,4`."
  defmacro start_async(socket, name, fun) do
    warn_on_socket_capture!(fun, :start_async, __CALLER__)

    quote do
      Async.start_async(unquote(socket), unquote(name), unquote(fun))
    end
  end

  defmacro start_async(socket, name, fun, opts) do
    warn_on_socket_capture!(fun, :start_async, __CALLER__)

    quote do
      Async.start_async(unquote(socket), unquote(name), unquote(fun), unquote(opts))
    end
  end

  @doc "See `Arbor.Async.stream_async/3,4`."
  defmacro stream_async(socket, name, fun) do
    warn_on_socket_capture!(fun, :stream_async, __CALLER__)

    quote do
      Async.stream_async(unquote(socket), unquote(name), unquote(fun))
    end
  end

  defmacro stream_async(socket, name, fun, opts) do
    warn_on_socket_capture!(fun, :stream_async, __CALLER__)

    quote do
      Async.stream_async(unquote(socket), unquote(name), unquote(fun), unquote(opts))
    end
  end

  @doc "See `Arbor.Async.cancel_async/2,3`."
  defmacro cancel_async(socket, target) do
    quote do
      Async.cancel_async(unquote(socket), unquote(target))
    end
  end

  defmacro cancel_async(socket, target, reason) do
    quote do
      Async.cancel_async(unquote(socket), unquote(target), unquote(reason))
    end
  end

  @spec warn_on_socket_capture!(Macro.t(), atom(), Macro.Env.t()) :: :ok
  defp warn_on_socket_capture!(fun_ast, fun_name, caller) do
    if captures_socket?(fun_ast) do
      IO.warn(
        "#{fun_name}/3,4: the task fn captures `socket`. " <>
          "Capturing the socket inside an async fun frozen at call time risks data races; " <>
          "bind the values you need to local variables before the fn instead.",
        Macro.Env.stacktrace(caller)
      )
    end

    :ok
  end

  @spec captures_socket?(Macro.t()) :: boolean()
  defp captures_socket?(ast) do
    {_ast, captured?} =
      Macro.prewalk(ast, false, fn
        {:socket, _meta, ctx} = node, _acc when is_atom(ctx) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    captured?
  end
end
