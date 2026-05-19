# Uploads — end-to-end example

A minimal sketch of a single-upload feature wired across the server,
the transport, and the React client. Combine with the full reference
at `docs/uploads.md`.

## Server

```elixir
defmodule MyApp.Stores.AvatarStore do
  use Musubi.Store, root: true

  state do
    field :avatar_url, String.t() | nil
  end

  upload :avatar,
    accept: ~w(.jpg .jpeg .png),
    max_entries: 1,
    max_file_size: 5_000_000

  command :submit

  @impl Musubi.Store
  def render(socket), do: %{avatar_url: socket.assigns.avatar_url}

  @impl Musubi.Store
  def handle_command(:submit, _payload, socket) do
    {socket, [url]} =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        # Copy the temp file into permanent storage; return the public URL.
        dest = Path.join(["priv", "static", "uploads", entry.client_name])
        File.cp!(path, dest)
        {:ok, "/uploads/#{entry.client_name}"}
      end)

    {:reply, %{ok: true}, assign(socket, :avatar_url, url)}
  end
end
```

## Socket

```elixir
defmodule MyAppWeb.MusubiSocket do
  use Musubi.Socket,
    roots: [MyApp.Stores.AvatarStore]
end
```

`use Musubi.Socket` automatically registers both the connection
channel (`musubi:*`) and the per-entry upload channel
(`musubi_upload:*`).

## React UI

```tsx
import { S3Uploader, useMusubiRoot } from "@musubi/react"

export function AvatarUploader() {
  const { store } = useMusubiRoot({
    module: "MyApp.Stores.AvatarStore",
    id: "u:42"
  })

  if (!store) return <p>Loading…</p>

  const avatar = store.avatar // resolved UploadHandle

  return (
    <div>
      <input
        type="file"
        accept={Array.isArray(avatar.config.accept) ? avatar.config.accept.join(",") : undefined}
        onChange={async (event) => {
          if (!event.target.files) return
          await avatar.select(event.target.files)
          await avatar.start()
        }}
      />

      {avatar.isUploading && <progress value={avatar.progress} max={100} />}

      {avatar.errors.map((err) => (
        <p key={err.code}>{err.message}</p>
      ))}

      <button
        disabled={!avatar.isSuccess}
        onClick={() => store.dispatchCommand("submit", {})}
      >
        Save
      </button>

      {store.avatar_url && <img src={store.avatar_url} alt="avatar" />}
    </div>
  )
}
```

## External (S3 / R2) mode

Switching the upload to direct-to-cloud requires an additional
callback on the store:

```elixir
@impl Musubi.Store
def upload_external(:avatar, entry, socket) do
  # Stash whatever your :submit handler needs to verify or finalize
  # the upload (here we keep the eventual public URL).
  public_url = MyApp.S3.public_url(entry)
  {presigned_url, headers} = MyApp.S3.presign_put(entry)

  meta = %{
    uploader: "S3",
    url: presigned_url,
    headers: headers,
    public_url: public_url
  }

  {:ok, meta, socket}
end
```

The meta map is opaque to Musubi — pick the shape your client uploader
expects (the built-in `S3Uploader` reads `meta.url` + `meta.headers`)
plus whatever fields you want available at consume time.

Consuming the upload in a command handler looks identical to channel
mode, but the meta carries the *external* key instead of *path*:

```elixir
@impl Musubi.Store
def handle_command(:submit, _payload, socket) do
  {socket, [url]} =
    consume_uploaded_entries(socket, :avatar, fn meta, entry ->
      # `meta` shape in external mode: %{external: meta_returned_by_upload_external}.
      %{external: %{public_url: public_url}} = meta

      # Optionally HEAD the object to confirm the client actually PUT it.
      :ok = MyApp.S3.assert_present!(entry.client_name)
      {:ok, public_url}
    end)

  {:reply, %{ok: true}, assign(socket, :avatar_url, url)}
end
```

Register the `S3Uploader` on the client side through the
`MusubiProvider`:

```tsx
import { Socket } from "phoenix"
import { MusubiProvider, S3Uploader } from "@musubi/react"

const socket = new Socket("/socket")

export function App() {
  return (
    <MusubiProvider socket={socket} uploaders={{ S3: S3Uploader }}>
      <AvatarUploader />
    </MusubiProvider>
  )
}
```

The wire protocol is identical to channel mode — the only difference
is that the preflight reply carries `{type: "external", uploader,
meta}` instead of a Musubi-signed token. `S3Uploader` PUTs directly to
the presigned URL and reports progress back through the main channel;
on failure it sends `upload_error` and the server emits
`{op: error, code: "external_failed"}`.
