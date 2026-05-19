defmodule Musubi.Upload.Config do
  @moduledoc """
  Compile-time configuration for a single declared upload.

  Built from the `upload :name, opts` macro and stored on the store
  module's reflection metadata. Carries every authority signal needed
  during preflight (max_entries, max_file_size, accept list) and the
  channel-mode tuning knobs (chunk_size, chunk_timeout).

  Mirrors `Musubi.Stream`'s compile-time descriptor pattern.
  """

  use TypedStructor

  @type accept() :: [String.t()] | :any
  @type name() :: atom()

  typed_structor do
    field :name, name(),
      enforce: true,
      doc: "Upload identifier matching the `upload :name, opts` declaration."

    field :accept, accept(),
      enforce: true,
      doc: "List of accepted file extensions (each starting with `.`) or the atom `:any`."

    field :max_entries, pos_integer(),
      default: 1,
      doc: "Maximum number of simultaneously-tracked entries for this upload."

    field :max_file_size, pos_integer(),
      default: 8_000_000,
      doc: "Maximum size per entry, in bytes."

    field :chunk_size, pos_integer(),
      default: 64_000,
      doc:
        "Default channel chunk size, in bytes. Embedded in the signed token; the sub-channel rejects oversized chunks."

    field :chunk_timeout, pos_integer(),
      default: 10_000,
      doc:
        "Maximum number of milliseconds between consecutive chunk events on the per-entry sub-channel before the channel terminates."
  end

  @doc false
  @spec defaults() :: %{atom() => term()}
  def defaults do
    %{
      max_entries: 1,
      max_file_size: 8_000_000,
      chunk_size: 64_000,
      chunk_timeout: 10_000
    }
  end

  @doc """
  Builds a config from the raw keyword opts supplied to `upload/2,3`.

  Validates `:accept` is present and shaped as either a list of extensions
  or the atom `:any`. Other recognized options pass through with their
  declared defaults. Raises `ArgumentError` on missing or malformed input.
  """
  @spec new(name(), keyword()) :: t()
  def new(name, opts) when is_atom(name) and is_list(opts) do
    accept = validate_accept!(name, opts)

    %__MODULE__{
      name: name,
      accept: accept,
      max_entries: validate_pos!(name, opts, :max_entries, defaults().max_entries),
      max_file_size: validate_pos!(name, opts, :max_file_size, defaults().max_file_size),
      chunk_size: validate_pos!(name, opts, :chunk_size, defaults().chunk_size),
      chunk_timeout: validate_pos!(name, opts, :chunk_timeout, defaults().chunk_timeout)
    }
  end

  @doc "Wire-shape config map sent to the client during preflight."
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = config) do
    %{
      "accept" => accept_to_wire(config.accept),
      "max_entries" => config.max_entries,
      "max_file_size" => config.max_file_size,
      "chunk_size" => config.chunk_size
    }
  end

  defp accept_to_wire(:any), do: "any"
  defp accept_to_wire(list) when is_list(list), do: list

  @doc """
  Checks whether `client_name` and `client_type` are admitted by `accept`.

  `:any` always succeeds. List form matches by case-insensitive file
  extension on `client_name`.
  """
  @spec accepted?(t(), String.t(), String.t()) :: boolean()
  def accepted?(%__MODULE__{accept: :any}, _client_name, _client_type), do: true

  def accepted?(%__MODULE__{accept: accept}, client_name, _client_type)
      when is_binary(client_name) and is_list(accept) do
    ext = client_name |> Path.extname() |> String.downcase()
    Enum.any?(accept, fn entry -> is_binary(entry) and String.downcase(entry) == ext end)
  end

  defp validate_accept!(name, opts) do
    case Keyword.fetch(opts, :accept) do
      {:ok, :any} ->
        :any

      {:ok, list} when is_list(list) ->
        Enum.each(list, fn
          entry when is_binary(entry) ->
            unless String.starts_with?(entry, ".") do
              raise ArgumentError,
                    "upload :#{name} accept entries must start with `.` (got: #{inspect(entry)})"
            end

          other ->
            raise ArgumentError,
                  "upload :#{name} accept entries must be binaries (got: #{inspect(other)})"
        end)

        list

      {:ok, other} ->
        raise ArgumentError,
              "upload :#{name} accept must be a list of extensions or :any (got: #{inspect(other)})"

      :error ->
        raise ArgumentError,
              "upload :#{name} requires the :accept option"
    end
  end

  defp validate_pos!(name, opts, key, default) do
    case Keyword.fetch(opts, key) do
      :error ->
        default

      {:ok, value} when is_integer(value) and value > 0 ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "upload :#{name} option #{inspect(key)} must be a positive integer (got: #{inspect(other)})"
    end
  end

  @doc false
  @spec valid_options() :: [atom()]
  def valid_options, do: [:accept, :max_entries, :max_file_size, :chunk_size, :chunk_timeout]
end
