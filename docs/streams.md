# Streams

Streams are for collections whose item values should not remain in server
memory after delivery. Arbor keeps stream configuration and pending delta ops
on the server, while the client owns the materialized list.

## State Declaration

Declare streams inside `state do`. A stream may be top-level or nested under
plain object fields, but each stream name must be unique within one store.

```elixir
state do
  field :feed do
    stream :messages, item_key: &"msg-#{&1.id}", limit: -100 do
      field :id, String.t()
      field :body, String.t()
    end
  end

  stream :users, UserState.t(), item_key: &"user-#{&1.id}"
  field :title, String.t()
end
```

Top-level streams can use a named Arbor state module, a map type, or an inline
block. Nested inline blocks are useful when the item shape belongs only to that
store output.

## Render Placement

`render/1` must explicitly place each declared stream with `stream(:name)` at
the same path where it was declared.

```elixir
def render(socket) do
  %{
    title: socket.assigns.title,
    feed: %{messages: stream(:messages)},
    users: stream(:users)
  }
end
```

The old placeholder shape, such as `messages: []`, is invalid. Arbor also
rejects hand-written stream marker maps, undeclared streams, missing stream
placements, duplicate placements, and placements at the wrong state path.

## Wire Shape

The state tree carries only a marker at the stream path:

```json
{
  "title": "Inbox",
  "feed": {
    "messages": { "__arbor_stream__": "messages" }
  },
  "users": { "__arbor_stream__": "users" },
  "__arbor_store_id__": []
}
```

The marker needs only the stream name. Ownership and ordering metadata stay in
`stream_ops`, where each op carries `store_id`, `stream`, and `ref`.

```json
{
  "type": "patch",
  "base_version": 0,
  "version": 1,
  "ops": [
    { "op": "replace", "path": "", "value": { "feed": { "messages": { "__arbor_stream__": "messages" } } } }
  ],
  "stream_ops": [
    {
      "op": "insert",
      "stream": "messages",
      "ref": "1",
      "store_id": [],
      "item_key": "msg-1",
      "at": -1,
      "item": { "id": "1", "body": "hello" },
      "limit": -100
    }
  ]
}
```

JSON Patch ops never carry stream item content. Stream item content flows
through `stream_ops` only.

## Runtime API

The socket helpers mirror Phoenix LiveView streams, with item-key terminology:

- `stream(socket, name, items, opts \\ [])`
- `stream_configure(socket, name, opts)`
- `stream_insert(socket, name, item, opts \\ [])`
- `stream_delete(socket, name, item)`
- `stream_delete_by_item_key(socket, name, item_key)`

Supported options include `:item_key`, `:limit`, `:at`, `:reset`, and
`:update_only`. `stream_configure/3` must run before the stream is initialized.

After each render cycle, pending stream ops are drained into the patch envelope
and the server drops item values. A cycle with non-empty `stream_ops` emits an
envelope even when JSON Patch `ops` is empty.

## Refresh

There is no separate reload API.

Use `stream(socket, name, fresh_items, reset: true)` when the application
already has fresh items. The runtime emits a reset followed by insert ops in
one envelope.

Use `stream_async(socket, name, fun, reset: true)` when the refresh requires a
background fetch and the UI should observe the async loading state.

## Client Surface

Generated TypeScript exposes stream fields as `Arbor.StreamField<Item>` for
type inference. At runtime, the client recursively resolves
`{ "__arbor_stream__": "name" }` markers into arrays:

```ts
root.feed.messages // Array<{ id: string; body: string }>
root.users         // Array<UserState>
```

Application code should not read or construct stream markers directly.
