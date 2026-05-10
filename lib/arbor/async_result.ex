defmodule Arbor.AsyncResult do
  @moduledoc """
  Three-field struct that tracks the lifecycle of an asynchronously-resolved
  socket assignment.

  Every assign written via `Arbor.Async.assign_async/3,4` (or seeded by
  `Arbor.Async.stream_async/3,4`) flows through one of the three statuses
  below so the client can pattern-match on a discriminated union.

  | `status`   | `result`                                     | `reason`                      |
  | :--------- | :------------------------------------------- | :---------------------------- |
  | `:loading` | prior `result` (or `nil`) — stale-while-load | `nil`                         |
  | `:ok`      | the value the user fun produced              | `nil`                         |
  | `:failed`  | prior `result` (or `nil`) — stale-while-fail | `{:error, _}` or `{:exit, _}` |

  ## Compile-time type marker

  `Arbor.AsyncResult.of(t)` is also the typespec marker used inside `state do`
  field declarations (see `Arbor.DSL.State`). The runtime struct and the
  compile-time marker share a name on purpose: a field declared as
  `field :profile, AsyncResult.of(UserProfileState.t())` accepts an
  `%Arbor.AsyncResult{}` at runtime.

  ## Examples

      iex> Arbor.AsyncResult.loading()
      %Arbor.AsyncResult{status: :loading, result: nil, reason: nil}

      iex> prior = %Arbor.AsyncResult{status: :ok, result: "snapshot", reason: nil}
      iex> Arbor.AsyncResult.loading(prior)
      %Arbor.AsyncResult{status: :loading, result: "snapshot", reason: nil}

      iex> Arbor.AsyncResult.ok(nil, %{name: "ada"})
      %Arbor.AsyncResult{status: :ok, result: %{name: "ada"}, reason: nil}

      iex> Arbor.AsyncResult.failed("snapshot", {:error, :timeout})
      %Arbor.AsyncResult{status: :failed, result: "snapshot", reason: {:error, :timeout}}
  """

  use TypedStructor

  @typedoc "Discriminated-union status enum surfaced on the wire."
  @type status() :: :loading | :ok | :failed

  @typedoc "Failure classification returned by the runtime."
  @type failure_reason() ::
          {:error, term()}
          | {:exit, term()}

  @typedoc "Compile-time field-type marker used inside `state do` declarations."
  @type of(value) :: %__MODULE__{
          status: status(),
          result: value | nil,
          reason: failure_reason() | nil
        }

  typed_structor do
    field :status, status(),
      default: :loading,
      doc:
        "Discriminated-union tag the client pattern-matches on. Serialized as a string on the wire."

    field :result, term(),
      default: nil,
      doc:
        "The value produced by the user function (when `status: :ok`), or the prior `:ok` result preserved for stale-while-loading/failed UX."

    field :reason, failure_reason() | nil,
      default: nil,
      doc:
        "Failure classification when `status: :failed`. `nil` while `:loading` or `:ok`. `{:error, term}` for explicit user errors; `{:exit, term}` for cancels, timeouts, exceptions, throws, exits."
  end

  @doc """
  Returns a fresh `%AsyncResult{}` in the `:loading` status with no prior result.

  ## Examples

      iex> Arbor.AsyncResult.loading()
      %Arbor.AsyncResult{status: :loading, result: nil, reason: nil}
  """
  @spec loading() :: t()
  def loading, do: %__MODULE__{status: :loading, result: nil, reason: nil}

  @doc """
  Returns a `:loading` `%AsyncResult{}` that preserves the prior `result` for
  stale-while-loading UX.

  Accepts either a previously-resolved `%AsyncResult{}` (its `result` is
  carried forward) or any raw value (used directly as the prior `result`).

  ## Examples

      iex> Arbor.AsyncResult.loading(%Arbor.AsyncResult{status: :ok, result: "snapshot"})
      %Arbor.AsyncResult{status: :loading, result: "snapshot", reason: nil}

      iex> Arbor.AsyncResult.loading("raw")
      %Arbor.AsyncResult{status: :loading, result: "raw", reason: nil}

      iex> Arbor.AsyncResult.loading(nil)
      %Arbor.AsyncResult{status: :loading, result: nil, reason: nil}
  """
  @spec loading(t() | term()) :: t()
  def loading(%__MODULE__{result: prior}), do: %__MODULE__{status: :loading, result: prior}
  def loading(prior), do: %__MODULE__{status: :loading, result: prior}

  @doc """
  Returns an `:ok` `%AsyncResult{}` carrying the produced value. The `prior`
  argument is accepted for symmetry with `loading/1`/`failed/2`; on success
  the new `result` always replaces the prior one.

  ## Examples

      iex> Arbor.AsyncResult.ok(%Arbor.AsyncResult{status: :loading}, %{name: "ada"})
      %Arbor.AsyncResult{status: :ok, result: %{name: "ada"}, reason: nil}

      iex> Arbor.AsyncResult.ok(nil, 42)
      %Arbor.AsyncResult{status: :ok, result: 42, reason: nil}
  """
  @spec ok(t() | term(), term()) :: t()
  def ok(_prior, value), do: %__MODULE__{status: :ok, result: value, reason: nil}

  @doc """
  Returns a `:failed` `%AsyncResult{}` that preserves the prior `result` for
  stale-while-failed UX. `reason` must be `{:error, term}` or `{:exit, term}`.

  ## Examples

      iex> Arbor.AsyncResult.failed("snapshot", {:error, :unauthorized})
      %Arbor.AsyncResult{status: :failed, result: "snapshot", reason: {:error, :unauthorized}}

      iex> prior = %Arbor.AsyncResult{status: :ok, result: "snapshot"}
      iex> Arbor.AsyncResult.failed(prior, {:exit, :timeout})
      %Arbor.AsyncResult{status: :failed, result: "snapshot", reason: {:exit, :timeout}}
  """
  @spec failed(t() | term(), failure_reason()) :: t()
  def failed(%__MODULE__{result: prior}, reason),
    do: %__MODULE__{status: :failed, result: prior, reason: reason}

  def failed(prior, reason),
    do: %__MODULE__{status: :failed, result: prior, reason: reason}

  defimpl Arbor.Wire do
    @moduledoc false
    @spec to_wire(Arbor.AsyncResult.t()) :: %{required(String.t()) => term()}
    def to_wire(%Arbor.AsyncResult{status: status, result: result, reason: reason}) do
      %{
        "status" => Atom.to_string(status),
        "result" => Arbor.Wire.to_wire(result),
        "reason" => reason_to_wire(reason)
      }
    end

    defp reason_to_wire(nil), do: nil

    defp reason_to_wire({kind, payload}) when kind in [:error, :exit] do
      %{"kind" => Atom.to_string(kind), "value" => safe_wire(payload)}
    end

    defp reason_to_wire(other), do: safe_wire(other)

    # The `reason` payload may carry arbitrary terms — exception structs,
    # tuples (`{kind, reason, stacktrace}`), pids, refs — none of which are
    # required to implement `Arbor.Wire`. Inspect everything that does not
    # round-trip through the protocol so the wire stays JSON-safe.
    defp safe_wire(value) do
      Arbor.Wire.to_wire(value)
    rescue
      Protocol.UndefinedError -> inspect(value)
    end
  end
end
