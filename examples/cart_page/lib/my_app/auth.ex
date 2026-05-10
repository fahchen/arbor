defmodule MyApp.Auth do
  @moduledoc """
  Stub authorization. The `:current_user` assign is `nil` for unauthenticated
  pages and a `%{id, name}` map for signed-in pages — the value flows in
  through `attr :current_user` on the root store.
  """

  @doc "Returns true when the supplied user value indicates a signed-in session."
  @spec signed_in?(map() | nil) :: boolean()
  def signed_in?(nil), do: false
  def signed_in?(%{id: id}) when is_binary(id), do: true
  def signed_in?(_other), do: false
end
