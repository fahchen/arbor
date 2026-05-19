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

Switching the upload to direct-to-cloud requires only an additional
callback on the store:

```elixir
@impl Musubi.Store
def upload_external(:avatar, entry, socket) do
  {url, headers} = MyApp.S3.presign(entry)
  {:ok, %{uploader: "S3", url: url, headers: headers}, socket}
end
```

…and registering the `S3Uploader` on the client connection:

```tsx
import { createMusubi, S3Uploader } from "@musubi/react"

const musubi = createMusubi<Musubi.Stores>({
  socket,
  uploaders: { S3: S3Uploader }
})
```

The wire protocol is identical — the only difference is that the
preflight reply carries `{type: "external", uploader, meta}` instead
of a Musubi-signed token, and the client uploader (here `S3Uploader`)
PUTs directly to the presigned URL and reports progress back through
the main channel.
