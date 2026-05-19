defmodule Musubi.Lifecycle do
  @moduledoc """
  Lifecycle hook helpers for Musubi runtime stages.

  ## Stages

  | Stage              | Arity | Hook arguments                          |
  | :----------------- | :---- | :-------------------------------------- |
  | `:before_command`  | 3     | `(command_name, payload, socket)`       |
  | `:after_command`   | 4     | `(command_name, payload, reply, socket)`|
  | `:handle_async`    | 3     | `(name, async_result, socket)`          |
  | `:handle_info`     | 2     | `(message, socket)`                     |
  | `:after_render`   | 2     | `(resolved_elixir_term, socket)`        |
  | `:after_serialize` | 2     | `(wire_term, socket)`                   |

  `:after_render` runs after `Musubi.Resolver` substitutes child placeholders;
  it sees the Elixir-form output (atom keys, structs, atom values).
  `:after_serialize` runs after `Musubi.Wire.to_wire/1` converts the resolved
  output to wire form (string keys, plain maps, atoms-as-strings).
  """

  alias Musubi.Socket

  @type stage() ::
          :before_command
          | :after_command
          | :handle_async
          | :handle_info
          | :after_render
          | :after_serialize

  @type hook_id() :: term()
  @type hook_result() :: {:cont, Socket.t()} | {:halt, Socket.t()} | {:halt, term(), Socket.t()}
  @type hook_fun() :: function()
  @type hook_entry() :: %{id: hook_id(), fun: hook_fun()}
  @type hook_table() :: %{optional(stage()) => [hook_entry()]}

  @stages [
    :before_command,
    :after_command,
    :handle_async,
    :handle_info,
    :after_render,
    :after_serialize
  ]
  @stage_arity %{
    before_command: 3,
    after_command: 4,
    handle_async: 3,
    handle_info: 2,
    after_render: 2,
    after_serialize: 2
  }

  @doc """
  Attaches a lifecycle hook for the given stage.

  ## Examples

      iex> socket = %Musubi.Socket{}
      iex> socket =
      ...>   Musubi.Lifecycle.attach_hook(socket, :audit, :after_render, fn _output, socket ->
      ...>     {:cont, socket}
      ...>   end)
      iex> Musubi.Socket.get_private(socket, :hooks)[:after_render] |> length()
      1
  """
  @spec attach_hook(Socket.t(), hook_id(), stage(), hook_fun()) :: Socket.t()
  def attach_hook(%Socket{} = socket, id, stage, fun)
      when stage in @stages and is_function(fun) do
    validate_hook_arity!(stage, fun)
    hooks = hooks(socket)
    stage_hooks = Map.get(hooks, stage, [])

    if Enum.any?(stage_hooks, &(&1.id == id)) do
      raise ArgumentError, "hook #{inspect(id)} already attached for stage #{inspect(stage)}"
    end

    next_stage_hooks = List.insert_at(stage_hooks, -1, %{id: id, fun: fun})
    put_hooks(socket, Map.put(hooks, stage, next_stage_hooks))
  end

  @doc """
  Detaches a lifecycle hook when one is present.

  ## Examples

      iex> socket =
      ...>   Musubi.Lifecycle.attach_hook(%Musubi.Socket{}, :audit, :after_render, fn _output, socket ->
      ...>     {:cont, socket}
      ...>   end)
      iex> socket = Musubi.Lifecycle.detach_hook(socket, :audit, :after_render)
      iex> Musubi.Socket.get_private(socket, :hooks)
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
      ...>   Musubi.Lifecycle.attach_hook(%Musubi.Socket{}, :mark, :after_render, fn _output, socket ->
      ...>     {:cont, Musubi.Socket.assign(socket, :seen?, true)}
      ...>   end)
      iex> {:cont, socket} = Musubi.Lifecycle.run_hooks(socket, :after_render, [%{title: "Inbox"}], false)
      iex> socket.assigns.seen?
      true
  """
  @spec run_hooks(Socket.t(), stage(), list(), boolean()) ::
          {:cont, Socket.t()} | {:halt, Socket.t()} | {:halt, term(), Socket.t()}
  def run_hooks(%Socket{} = socket, stage, hook_args, halt_payloads_allowed?)
      when stage in @stages and is_list(hook_args) and is_boolean(halt_payloads_allowed?) do
    socket
    |> hooks()
    |> Map.get(stage, [])
    |> Enum.reduce_while({:cont, socket}, fn %{fun: fun}, {:cont, current_socket} ->
      # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
      case apply(fun, hook_args ++ [current_socket]) do
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

      iex> Musubi.Lifecycle.stages()
      [:before_command, :after_command, :handle_async, :handle_info, :after_render, :after_serialize]
  """
  @spec stages() :: [stage()]
  def stages, do: @stages

  @doc """
  Returns the required hook function arity for a lifecycle stage.

  | Stage              | Arity | Hook arguments                          |
  | :----------------- | :---- | :-------------------------------------- |
  | `:before_command`  | 3     | `(command_name, payload, socket)`       |
  | `:after_command`   | 4     | `(command_name, payload, reply, socket)`|
  | `:handle_async`    | 3     | `(name, async_result, socket)`          |
  | `:handle_info`     | 2     | `(message, socket)`                     |
  | `:after_render`   | 2     | `(resolved_elixir_term, socket)`        |
  | `:after_serialize` | 2     | `(wire_term, socket)`                   |

  ## Examples

      iex> Musubi.Lifecycle.stage_arity(:before_command)
      3
      iex> Musubi.Lifecycle.stage_arity(:after_command)
      4
      iex> Musubi.Lifecycle.stage_arity(:after_serialize)
      2
  """
  @spec stage_arity(stage()) :: 2 | 3 | 4
  def stage_arity(stage) when stage in @stages do
    Map.fetch!(@stage_arity, stage)
  end

  def stage_arity(stage) do
    raise ArgumentError, "unknown lifecycle stage: #{inspect(stage)}"
  end

  @spec hooks(Socket.t()) :: hook_table()
  defp hooks(%Socket{private: private}), do: Map.get(private, :hooks, %{})

  @spec validate_hook_arity!(stage(), function()) :: :ok
  defp validate_hook_arity!(stage, fun) when is_function(fun) do
    expected_arity = stage_arity(stage)
    {:arity, actual_arity} = :erlang.fun_info(fun, :arity)

    if actual_arity == expected_arity do
      :ok
    else
      raise ArgumentError,
            "expected fun arity #{expected_arity} for stage #{inspect(stage)}, got arity #{actual_arity}"
    end
  end

  @spec put_hooks(Socket.t(), hook_table()) :: Socket.t()
  defp put_hooks(%Socket{private: private} = socket, hooks) do
    %{socket | private: Map.put(private, :hooks, hooks)}
  end
end
