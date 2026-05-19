defmodule Musubi.Upload.Token do
  @moduledoc """
  Signs and verifies the Phoenix.Token used to authorize per-entry upload
  sub-channels.

  Centralizes the salt and max-age so the issuing path (page server during
  preflight) and the verifying path (`Musubi.Transport.UploadChannel.join/3`)
  never disagree on the contract.

  ## Payload

      %{
        store_pid:     pid(),
        conf_ref:      String.t(),   # upload name as a string
        entry_ref:     String.t(),
        max_file_size: integer(),
        accept:        [String.t()] | :any,
        chunk_size:    integer()
      }

  See BDR-0026.
  """

  @salt "musubi_upload"
  @max_age 600

  @type payload() :: %{
          required(:store_pid) => pid(),
          required(:store_id) => [String.t()],
          required(:conf_ref) => String.t(),
          required(:entry_ref) => String.t(),
          required(:max_file_size) => pos_integer(),
          required(:accept) => [String.t()] | :any,
          required(:chunk_size) => pos_integer()
        }

  @doc "Returns the well-known salt used for token signing."
  @spec salt() :: String.t()
  def salt, do: @salt

  @doc "Returns the well-known max-age applied at verification."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc "Signs a payload with the given endpoint."
  @spec sign(module(), payload()) :: String.t()
  def sign(endpoint, payload) when is_atom(endpoint) and is_map(payload) do
    Phoenix.Token.sign(endpoint, @salt, payload)
  end

  @doc """
  Verifies a token issued by `sign/2`, returning the payload on success.

  Rejects expired and forged tokens. Returns `{:error, atom}` matching
  Phoenix.Token's contract.
  """
  @spec verify(module(), String.t()) :: {:ok, payload()} | {:error, atom()}
  def verify(endpoint, token) when is_atom(endpoint) and is_binary(token) do
    Phoenix.Token.verify(endpoint, @salt, token, max_age: @max_age)
  end
end
