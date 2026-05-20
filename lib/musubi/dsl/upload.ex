defmodule Musubi.DSL.Upload do
  @moduledoc false

  @doc """
  Declares a top-level upload slot on a `Musubi.Store` module.

  Only valid at the top level of a store. Compile-time validations
  performed here:

    * `:accept` is required and shaped per `Musubi.Upload.Config`.
    * Upload names must be unique within one store.
    * Upload names must not collide with state field names — `page.<name>`
      is flat on the client and the merged TypeScript surface would be
      ambiguous.

  ## Examples

      defmodule AvatarStore do
        use Musubi.Store, root: true

        state do
          field :avatar_url, String.t() | nil
        end

        upload :avatar,
          accept: ~w(.jpg .jpeg .png),
          max_entries: 1,
          max_file_size: 5_000_000
      end
  """
  @spec upload(atom(), keyword()) :: Macro.t()
  defmacro upload(name, opts) when is_atom(name) and is_list(opts) do
    file = __CALLER__.file
    line = __CALLER__.line

    quote bind_quoted: [name: name, opts: opts, file: file, line: line] do
      Musubi.DSL.Upload.__register__(__MODULE__, name, opts, file, line)
    end
  end

  @doc false
  @spec __register__(module(), atom(), keyword(), String.t(), pos_integer()) :: :ok
  def __register__(module, name, opts, file, line)
      when is_atom(module) and is_atom(name) and is_list(opts) and is_binary(file) and
             is_integer(line) do
    config = Musubi.Upload.Config.new(name, opts)

    existing = Module.get_attribute(module, :__musubi_uploads__) || []

    case Enum.find(existing, fn {existing_name, _conf, _file, _line} -> existing_name == name end) do
      nil ->
        # Compile-time list of {name, config, file, line} tuples. The list
        # stays short (one entry per declared upload) and order matters,
        # so the tail-insert is O(declared_uploads); not a hot path.
        next = List.insert_at(existing, -1, {name, config, file, line})
        Module.put_attribute(module, :__musubi_uploads__, next)
        :ok

      {_existing_name, _conf, prev_file, prev_line} ->
        raise CompileError,
          file: file,
          line: line,
          description:
            "duplicate upload declaration #{inspect(name)} on #{inspect(module)} " <>
              "(previously declared at #{Path.relative_to_cwd(prev_file)}:#{prev_line})"
    end
  end

  @doc false
  @spec __forbid_inside_state__(atom(), Macro.Env.t()) :: no_return()
  def __forbid_inside_state__(name, %Macro.Env{} = caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "upload :#{name} not allowed inside `state do` / `field` / `stream` / list type spec — " <>
          "uploads must be declared at the top level of a store module"
  end
end
