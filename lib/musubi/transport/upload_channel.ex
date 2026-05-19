defmodule Musubi.Transport.UploadChannel do
  @moduledoc """
  Per-entry chunk sub-channel for Musubi uploads.

  Topic: `"musubi_upload:<entry_ref>"`. Joined with the Phoenix.Token
  issued during the `allow_upload` preflight (BDR-0026).

  ## Statelessness

  The channel never consults a shared authorization table. Every
  authority signal it enforces (`max_file_size`, `chunk_size`, owning
  store pid, upload name) is recovered from the verified token payload
  on `join/3`.

  ## Lifecycle

    * `join/3` — verifies the token, confirms `store_pid` is alive,
      opens a `Plug.Upload.random_file/1` temp file.
    * `handle_in("chunk", binary, socket)` — appends the binary frame
      to the temp file, enforces the per-token chunk size and total
      size, notifies the page server, and replies `%{progress: N}`.
    * `terminate/2` — closes the temp file. On unexpected termination
      (no consumption) the temp file is removed and the runtime sees a
      `{:cancel}` op.

  ## Mounting in a Phoenix UserSocket

      defmodule MyAppWeb.UserSocket do
        use Musubi.Socket, roots: [MyApp.Stores.AvatarStore]

        channel "musubi_upload:*", Musubi.Transport.UploadChannel
      end
  """

  use Phoenix.Channel

  alias Musubi.Page.Server
  alias Musubi.Upload.Error
  alias Musubi.Upload.Token

  @topic_prefix "musubi_upload:"

  # Phoenix socket assigns we own on this channel.
  @assigns %{
    payload: :__musubi_upload_payload__,
    name: :__musubi_upload_name__,
    file_pid: :__musubi_upload_file_pid__,
    file_path: :__musubi_upload_file_path__,
    bytes_written: :__musubi_upload_bytes_written__,
    consumed: :__musubi_upload_consumed__
  }

  @impl Phoenix.Channel
  def join(@topic_prefix <> entry_ref, %{"token" => token}, %Phoenix.Socket{} = socket)
      when is_binary(token) and entry_ref != "" do
    with {:ok, payload} <- Token.verify(socket.endpoint, token),
         :ok <- ensure_entry_ref(payload, entry_ref),
         :ok <- ensure_store_alive(payload),
         {:ok, file_path, file_pid} <- open_temp_file() do
      name_atom = String.to_existing_atom(payload.conf_ref)
      store_pid = payload.store_pid
      store_id = payload.store_id

      Server.register_upload_channel(store_pid, store_id, name_atom, entry_ref, self())

      socket =
        socket
        |> Phoenix.Socket.assign(@assigns.payload, payload)
        |> Phoenix.Socket.assign(@assigns.name, name_atom)
        |> Phoenix.Socket.assign(@assigns.file_pid, file_pid)
        |> Phoenix.Socket.assign(@assigns.file_path, file_path)
        |> Phoenix.Socket.assign(@assigns.bytes_written, 0)
        |> Phoenix.Socket.assign(@assigns.consumed, false)

      Process.flag(:trap_exit, true)

      {:ok, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl Phoenix.Channel
  def handle_in("chunk", binary, %Phoenix.Socket{} = socket) when is_binary(binary) do
    payload = socket.assigns[@assigns.payload]
    name = socket.assigns[@assigns.name]
    file_pid = socket.assigns[@assigns.file_pid]
    bytes = socket.assigns[@assigns.bytes_written]
    store_id = payload.store_id

    cond do
      byte_size(binary) > payload.chunk_size ->
        notify_error(payload.store_pid, store_id, name, payload.entry_ref, :chunk_too_large)
        {:stop, :normal, {:error, %{reason: "chunk too large"}}, socket}

      bytes + byte_size(binary) > payload.max_file_size ->
        notify_error(payload.store_pid, store_id, name, payload.entry_ref, :too_large)
        {:stop, :normal, {:error, %{reason: "upload too large"}}, socket}

      true ->
        :ok = IO.binwrite(file_pid, binary)
        next_bytes = bytes + byte_size(binary)

        # Heuristic completion: when the running total matches an entry's
        # client-reported `client_size`, the page server will set status to
        # `:success`. The channel itself does not know the size; we report
        # the chunk and let the page server compare.
        Server.upload_channel_chunk(
          payload.store_pid,
          store_id,
          name,
          payload.entry_ref,
          next_bytes,
          false
        )

        progress = compute_progress(next_bytes, payload.max_file_size)

        socket = Phoenix.Socket.assign(socket, @assigns.bytes_written, next_bytes)

        {:reply, {:ok, %{progress: progress, bytes_written: next_bytes}}, socket}
    end
  end

  def handle_in("close", _payload, %Phoenix.Socket{} = socket) do
    payload = socket.assigns[@assigns.payload]
    name = socket.assigns[@assigns.name]
    bytes = socket.assigns[@assigns.bytes_written]
    store_id = payload.store_id

    socket = Phoenix.Socket.assign(socket, @assigns.consumed, true)

    Server.upload_channel_chunk(
      payload.store_pid,
      store_id,
      name,
      payload.entry_ref,
      bytes,
      true
    )

    {:stop, :normal, {:ok, %{}}, socket}
  end

  @impl Phoenix.Channel
  def terminate(_reason, %Phoenix.Socket{} = socket) do
    file_pid = socket.assigns[@assigns.file_pid]
    file_path = socket.assigns[@assigns.file_path]
    consumed? = socket.assigns[@assigns.consumed] || false

    if is_pid(file_pid) and Process.alive?(file_pid), do: File.close(file_pid)

    if not consumed? do
      if is_binary(file_path), do: _ = File.rm(file_path)

      payload = socket.assigns[@assigns.payload]
      name = socket.assigns[@assigns.name]

      if payload && name do
        store_id = payload.store_id

        if Process.alive?(payload.store_pid) do
          Server.cancel_upload(payload.store_pid, store_id, name, payload.entry_ref)
        end
      end
    end

    :ok
  end

  defp ensure_entry_ref(%{entry_ref: ref}, ref), do: :ok
  defp ensure_entry_ref(_payload, _entry_ref), do: {:error, :mismatched_entry_ref}

  defp ensure_store_alive(%{store_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: :ok, else: {:error, :store_dead}
  end

  defp ensure_store_alive(_payload), do: {:error, :missing_store}

  defp open_temp_file do
    path = Plug.Upload.random_file!("musubi_upload")
    {:ok, pid} = File.open(path, [:write, :binary])
    {:ok, path, pid}
  end

  defp notify_error(store_pid, store_id, name, entry_ref, code) do
    GenServer.cast(
      store_pid,
      {:upload_channel_error, store_id, name, entry_ref, Error.new(code)}
    )

    :ok
  end

  defp compute_progress(_bytes, 0), do: 0
  defp compute_progress(bytes, total) when bytes >= total, do: 100

  defp compute_progress(bytes, total) when is_integer(bytes) and is_integer(total) and total > 0 do
    div(bytes * 100, total)
  end
end
