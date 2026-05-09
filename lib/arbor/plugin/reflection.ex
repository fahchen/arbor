defmodule Arbor.Plugin.Reflection do
  @moduledoc false

  use TypedStructor.Plugin

  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :__arbor_fields__) || []
    streams = Arbor.Plugin.StateField.stream_fields(fields)

    commands =
      env.module
      |> Module.get_attribute(:__arbor_commands__)
      |> List.wrap()
      |> Enum.reverse()

    attrs =
      env.module
      |> Module.get_attribute(:__arbor_attrs__)
      |> List.wrap()
      |> Enum.reverse()

    type_clauses =
      for %{name: name, type: type} <- fields do
        quote do
          def __arbor__(:type, unquote(name)), do: unquote(Macro.escape(type))
        end
      end

    quote do
      def __arbor__(:fields), do: unquote(Macro.escape(fields))
      def __arbor__(:commands), do: unquote(Macro.escape(commands))
      def __arbor__(:streams), do: unquote(Macro.escape(streams))
      def __arbor__(:attrs), do: unquote(Macro.escape(attrs))

      unquote_splicing(type_clauses)
    end
  end

  @impl TypedStructor.Plugin
  defmacro init(_opts) do
    quote do
      @before_compile Arbor.Plugin.Reflection
    end
  end
end
