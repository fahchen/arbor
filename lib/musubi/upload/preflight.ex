defmodule Musubi.Upload.Preflight do
  @moduledoc false

  alias Musubi.Socket
  alias Musubi.Upload
  alias Musubi.Upload.Config
  alias Musubi.Upload.Entry
  alias Musubi.Upload.Error
  alias Musubi.Upload.Token

  @type input_entry() :: %{
          required(String.t()) => term()
        }

  @type accepted() ::
          %{type: :channel, entry_ref: String.t(), token: String.t(), entry: Entry.t()}
          | %{type: :external, entry_ref: String.t(), uploader: String.t(), meta: map(), entry: Entry.t()}

  @type errored() :: %{client_ref: String.t(), error: Error.t()}

  @type result() :: %{
          accepted: [{String.t(), accepted()}],
          errors: [errored()],
          socket: Socket.t()
        }

  @doc """
  Validates an `allow_upload` payload, signs entry tokens, and returns
  the accepted entries (with their `client_ref`) and errored entries.

  The `socket` returned has each accepted entry inserted into the
  upload index and an `{op: add}` enqueued for it.
  """
  @spec run(Socket.t(), atom(), [input_entry()], module(), pid(), [String.t()]) :: result()
  def run(%Socket{} = socket, name, entries, endpoint, store_pid, store_id)
      when is_atom(name) and is_list(entries) and is_atom(endpoint) and is_pid(store_pid) and
             is_list(store_id) do
    config = fetch_config!(socket, name)
    external? = uses_external?(socket, name)
    existing_count = current_entry_count(socket, name)

    {accepted, errors, _next_count, next_socket} =
      Enum.reduce(
        entries,
        {[], [], existing_count, socket},
        fn input, {acc, err, count, sock} ->
          process_entry(
            input,
            name,
            config,
            count,
            external?,
            endpoint,
            store_pid,
            store_id,
            sock,
            acc,
            err
          )
        end
      )

    %{accepted: Enum.reverse(accepted), errors: Enum.reverse(errors), socket: next_socket}
  end

  defp process_entry(
         input,
         name,
         config,
         count,
         external?,
         endpoint,
         store_pid,
         store_id,
         socket,
         acc,
         err
       ) do
    with {:ok, client_ref} <- fetch_client_ref(input),
         {:ok, client_name} <- fetch_string(input, "name"),
         {:ok, client_size} <- fetch_size(input),
         client_type <- Map.get(input, "type", ""),
         :ok <- check_max_entries(config, count),
         :ok <- check_size(config, client_size),
         :ok <- check_accept(config, client_name, client_type) do
      entry_ref = generate_ref()
      now = System.monotonic_time()

      entry = %Entry{
        ref: entry_ref,
        client_name: client_name,
        client_size: client_size,
        client_type: client_type,
        progress: 0,
        status: :pending,
        errors: [],
        mode: if(external?, do: :external, else: :channel),
        store_pid: store_pid,
        preflighted_at: now
      }

      {entry, attach_meta} =
        attach_mode_meta(entry, name, config, endpoint, external?, store_id, socket)

      socket =
        socket
        |> Upload.put_entry(name, entry)
        |> Upload.enqueue_add(name, entry)

      accepted_entry = build_accepted(attach_meta, entry)
      {[{client_ref, accepted_entry} | acc], err, count + 1, socket}
    else
      {:error, %Error{} = error} ->
        client_ref = Map.get(input, "client_ref", "")
        {acc, [%{client_ref: client_ref, error: error} | err], count, socket}

      {:error, reason} when is_atom(reason) ->
        client_ref = Map.get(input, "client_ref", "")
        error = Error.new(reason)
        {acc, [%{client_ref: client_ref, error: error} | err], count, socket}
    end
  end

  defp attach_mode_meta(
         %Entry{} = entry,
         name,
         config,
         endpoint,
         false = _external?,
         store_id,
         _socket
       ) do
    token =
      Token.sign(endpoint, %{
        store_pid: entry.store_pid,
        store_id: store_id,
        conf_ref: Atom.to_string(name),
        entry_ref: entry.ref,
        max_file_size: config.max_file_size,
        client_size: entry.client_size,
        accept: config.accept,
        chunk_size: config.chunk_size,
        chunk_timeout: config.chunk_timeout
      })

    {%{entry | token: token}, %{type: :channel, token: token}}
  end

  defp attach_mode_meta(
         %Entry{} = entry,
         name,
         _config,
         _endpoint,
         true,
         _store_id,
         %Socket{module: module} = socket
       ) do
    case module.upload_external(name, entry, socket) do
      {:ok, %{} = meta, %Socket{}} ->
        uploader = Map.get(meta, :uploader) || Map.get(meta, "uploader") || "external"
        rest = meta |> Map.drop([:uploader, "uploader"])
        {%{entry | external_meta: meta}, %{type: :external, uploader: to_string(uploader), meta: rest}}

      other ->
        raise ArgumentError,
              "bad return from #{inspect(module)}.upload_external/3: expected {:ok, meta, socket}, got: #{inspect(other)}"
    end
  end

  defp build_accepted(%{type: :channel, token: token}, %Entry{} = entry) do
    %{type: :channel, entry_ref: entry.ref, token: token, entry: entry}
  end

  defp build_accepted(%{type: :external, uploader: uploader, meta: meta}, %Entry{} = entry) do
    %{type: :external, entry_ref: entry.ref, uploader: uploader, meta: meta, entry: entry}
  end

  defp fetch_config!(%Socket{} = socket, name) do
    case Map.get(socket.assigns, Upload.assigns_key(), %{}) |> Map.get(name) do
      %{config: %Config{} = config} -> config
      _other -> compile_config!(socket, name)
    end
  end

  defp compile_config!(%Socket{module: module}, name) do
    case module.__musubi__(:upload, name) do
      {:ok, %Config{} = config} ->
        config

      :error ->
        raise ArgumentError, "upload :#{name} not declared on #{inspect(module)}"
    end
  end

  defp uses_external?(%Socket{module: module}, name) when is_atom(module) and is_atom(name) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :upload_external, 3) and
      function_uses_external_for_name?(module, name)
  end

  # `upload_external/3` may be defined for multiple uploads on a module; the
  # default assumption is that any declared upload routes through it. The
  # implementation guards inside the callback if it needs to vary per name.
  defp function_uses_external_for_name?(_module, _name), do: true

  defp current_entry_count(%Socket{} = socket, name) do
    case Map.get(socket.assigns, Upload.assigns_key(), %{}) |> Map.get(name) do
      %{entries: entries} -> map_size(entries)
      _other -> 0
    end
  end

  defp check_max_entries(%Config{max_entries: max}, count) when count < max, do: :ok
  defp check_max_entries(%Config{}, _count), do: {:error, :too_many_files}

  defp check_size(%Config{max_file_size: max}, size) when size <= max, do: :ok
  defp check_size(%Config{}, _size), do: {:error, :too_large}

  defp check_accept(%Config{} = config, client_name, client_type) do
    if Config.accepted?(config, client_name, client_type) do
      :ok
    else
      {:error, :not_accepted}
    end
  end

  defp fetch_client_ref(input) do
    case Map.get(input, "client_ref") do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :preflight_rejected}
    end
  end

  defp fetch_string(input, key) do
    case Map.get(input, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :preflight_rejected}
    end
  end

  defp fetch_size(input) do
    case Map.get(input, "size") do
      v when is_integer(v) and v >= 0 -> {:ok, v}
      _ -> {:error, :preflight_rejected}
    end
  end

  defp generate_ref do
    "u_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
