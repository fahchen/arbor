defmodule Musubi.Upload.Error do
  @moduledoc """
  Scrubbed upload error carried in entries and `{op: error}` upload ops.

  ## Why a struct

  Upload errors flow through the wire to the client and into telemetry.
  Both surfaces are externally visible, so the error format is constrained:

    * `code` — stable atom usable as a discriminator on the client.
    * `message` — user-facing string. Must contain no paths, pids, IP
      addresses, or token fragments.

  Use the constructors below to build errors; do not splice infrastructure
  detail into `message` ad-hoc.
  """

  use TypedStructor

  @type code() ::
          :too_large
          | :too_many_files
          | :not_accepted
          | :chunk_timeout
          | :chunk_too_large
          | :external_failed
          | :preflight_rejected
          | :internal

  typed_structor do
    field :code, code(), enforce: true, doc: "Stable atom discriminator."

    field :message, String.t(),
      enforce: true,
      doc: "User-facing message, scrubbed of infrastructure detail."
  end

  @doc "Builds an error from a known code with a default message."
  @spec new(code()) :: t()
  def new(code) when is_atom(code) do
    %__MODULE__{code: code, message: default_message(code)}
  end

  @doc "Builds an error with an explicit message; caller is responsible for scrub."
  @spec new(code(), String.t()) :: t()
  def new(code, message) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message}
  end

  @doc ~S'Wire-shape map: `%{"code" => "...", "message" => "..."}`.'
  @spec to_wire(t()) :: %{String.t() => String.t()}
  def to_wire(%__MODULE__{code: code, message: message}) do
    %{"code" => Atom.to_string(code), "message" => message}
  end

  @doc false
  @spec default_message(code()) :: String.t()
  def default_message(:too_large), do: "file exceeds the maximum size"
  def default_message(:too_many_files), do: "too many files selected"
  def default_message(:not_accepted), do: "file type is not accepted"
  def default_message(:chunk_timeout), do: "upload timed out between chunks"
  def default_message(:chunk_too_large), do: "chunk size exceeded the configured limit"
  def default_message(:external_failed), do: "external upload failed"
  def default_message(:preflight_rejected), do: "upload was rejected"
  def default_message(:internal), do: "internal upload error"
end
