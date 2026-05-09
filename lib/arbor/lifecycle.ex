defmodule Arbor.Lifecycle do
  @moduledoc "Lifecycle hook helpers for Arbor runtime stages. Mirrors `Phoenix.LiveView.Lifecycle`."

  alias Arbor.Socket

  @type stage ::
          :before_command
          | :after_command
          | :handle_async
          | :handle_info
          | :after_to_state

  @type hook_id :: term()
  @type hook_result :: {:cont, Socket.t()} | {:halt, Socket.t()} | {:halt, term(), Socket.t()}
  @type hook_fun :: (term(), Socket.t() -> hook_result())
  @type hook_entry :: %{id: hook_id(), fun: hook_fun()}
  @type hook_table :: %{optional(stage()) => [hook_entry()]}

  @stages [:before_command, :after_command, :handle_async, :handle_info, :after_to_state]

  @doc """
  Attaches a lifecycle hook for the given stage.

  ## Examples

      iex> socket = %Arbor.Socket{}
      iex> socket =
      ...>   Arbor.Lifecycle.attach_hook(socket, :audit, :after_to_state, fn _ctx, socket ->
      ...>     {:cont, socket}
      ...>   end)
      iex> Arbor.Socket.get_private(socket, :hooks)[:after_to_state] |> length()
      1
  """
  @spec attach_hook(Socket.t(), hook_id(), stage(), hook_fun()) :: Socket.t()
  def attach_hook(%Socket{} = socket, id, stage, fun)
      when stage in @stages and is_function(fun, 2) do
    hooks = hooks(socket)
    stage_hooks = Map.get(hooks, stage, [])

    if Enum.any?(stage_hooks, &(&1.id == id)) do
      raise ArgumentError, "hook #{inspect(id)} already attached for stage #{inspect(stage)}"
    end

    next_stage_hooks = Enum.reverse([%{id: id, fun: fun} | Enum.reverse(stage_hooks)])
    put_hooks(socket, Map.put(hooks, stage, next_stage_hooks))
  end

  @doc """
  Detaches a lifecycle hook when one is present.

  ## Examples

      iex> socket =
      ...>   Arbor.Lifecycle.attach_hook(%Arbor.Socket{}, :audit, :after_to_state, fn _ctx, socket ->
      ...>     {:cont, socket}
      ...>   end)
      iex> socket = Arbor.Lifecycle.detach_hook(socket, :audit, :after_to_state)
      iex> Arbor.Socket.get_private(socket, :hooks)
      %{}
  """
  @spec detach_hook(Socket.t(), hook_id(), stage()) :: Socket.t()
  def detach_hook(%Socket{} = socket, id, stage) when stage in @stages do
    hooks = hooks(socket)
    stage_hooks = Map.get(hooks, stage, [])
    filtered_hooks = Enum.reject(stage_hooks, &(&1.id == id))

    if filtered_hooks == stage_hooks do
      socket
    else
      next_hooks =
        case filtered_hooks do
          [] -> Map.delete(hooks, stage)
          _hooks -> Map.put(hooks, stage, filtered_hooks)
        end

      put_hooks(socket, next_hooks)
    end
  end

  @doc """
  Runs every hook registered for a stage until one halts or all continue.

  ## Examples

      iex> socket =
      ...>   Arbor.Lifecycle.attach_hook(%Arbor.Socket{}, :mark, :after_to_state, fn _ctx, socket ->
      ...>     {:cont, Arbor.Socket.assign(socket, :seen?, true)}
      ...>   end)
      iex> {:cont, socket} = Arbor.Lifecycle.run_hooks(socket, :after_to_state, %{title: "Inbox"}, false)
      iex> socket.assigns.seen?
      true
  """
  @spec run_hooks(Socket.t(), stage(), term(), boolean()) ::
          {:cont, Socket.t()} | {:halt, Socket.t()} | {:halt, term(), Socket.t()}
  def run_hooks(%Socket{} = socket, stage, ctx, halt_payloads_allowed?)
      when stage in @stages and is_boolean(halt_payloads_allowed?) do
    socket
    |> hooks()
    |> Map.get(stage, [])
    |> Enum.reduce_while({:cont, socket}, fn %{fun: fun}, {:cont, current_socket} ->
      case fun.(ctx, current_socket) do
        {:cont, %Socket{} = next_socket} ->
          {:cont, {:cont, next_socket}}

        {:halt, %Socket{} = next_socket} ->
          {:halt, {:halt, next_socket}}

        {:halt, reply, %Socket{} = next_socket} when halt_payloads_allowed? ->
          {:halt, {:halt, reply, next_socket}}

        {:halt, _reply, %Socket{}} ->
          raise ArgumentError,
                "halt payloads are only allowed when halt_payloads_allowed? is true"

        other ->
          raise ArgumentError, "invalid hook result: #{inspect(other)}"
      end
    end)
  end

  @doc """
  Returns the supported lifecycle stages in execution order.

  ## Examples

      iex> Arbor.Lifecycle.stages()
      [:before_command, :after_command, :handle_async, :handle_info, :after_to_state]
  """
  @spec stages() :: [stage()]
  def stages, do: @stages

  @spec hooks(Socket.t()) :: hook_table()
  defp hooks(%Socket{private: private}), do: Map.get(private, :hooks, %{})

  @spec put_hooks(Socket.t(), hook_table()) :: Socket.t()
  defp put_hooks(%Socket{private: private} = socket, hooks) do
    %{socket | private: Map.put(private, :hooks, hooks)}
  end
end
