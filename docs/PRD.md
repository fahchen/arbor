# Arbor — PRD and Milestone Plan

This PRD is the authoritative product description for Arbor. The wire-level and runtime contract is fully captured in `spec/` as Gherkin features and `BDR-NNNN` decision records; this document is the narrative that ties those pieces together. Where the spec and PRD disagree, the spec wins.

## Executive Summary

Arbor is a server-authoritative, page-scoped runtime library for Elixir/Phoenix. A single BEAM process per connected page owns a hierarchical tree of stores, routes commands to addressed nodes, computes a structured render output per node, resolves child-store placeholders, validates the resolved output against per-store schemas, diffs it against the previous resolved output, and pushes RFC 6902 JSON Patch updates plus stream-op envelopes to the client. Internal implementation state lives in `ctx.assigns` (one map per node, holding both parent-passed values and store-internal state). Only the resolved render output is exposed to the client.

The `state do` declaration is the single source of truth for the wire shape, the Elixir typespec, the TypeScript type, and the render-output validator. The wire transport is Phoenix Channel over WebSocket; commands receive ref-based replies and patches travel as separate channel pushes. The runtime mirrors `Phoenix.LiveView` semantics wherever practical and diverges deliberately when justified (recorded in BDRs).

## Product Definition

### Product statement

Arbor lets developers model page state as a hierarchical tree of stateful stores, hosted in one BEAM process per connected page. Children are composed via explicit `child(...)` placeholders in `render/1`, identified by `(parent_path, module, id)`, and live and die with the parent's render output. Cross-cutting concerns (audit, logging, feature flags) attach via `attach_hook/4`, mirroring `Phoenix.LiveView.attach_hook/4`. PubSub is not built in: stores subscribe via `Phoenix.PubSub.subscribe/2` directly and react via `handle_info/2`. Persistence is not built in: applications implement save/load using existing hook and middleware extension points.

### Goals

| Goal | Decision |
|------|----------|
| Single-process consistency | One runtime process per connected page (1:1 with transport). |
| Public/private state split via shape, not namespace | `state do` declares the public render-output shape; `ctx.assigns` is the single internal state container (BDR-0010). |
| Render contract | `render(ctx)` returns a value matching `state do`; `child(...)` placeholders are resolved bottom-up before validation/diffing. |
| Explicit ownership | Parent passes assigns (data + functions) via `child(...)`; child can only mutate its own `ctx.assigns`. |
| LV-aligned developer experience | Mount/update/render lifecycle, handle_info for messages, attach_hook for cross-cutting, AsyncResult for async, stream API for collections. |
| Predictable side effects | Plug-like middleware with halting + ordered hooks; effects via ctx-pipe (BDR-0006). |
| Addressable mutations | Commands route by node path plus command name; outcome via Phoenix Channel ref reply (BDR-0001). |
| Efficient replication | RFC 6902 JSON Patch, structural minimal diff with no threshold (BDR-0014). |
| Stream support | LiveView-parity stream API; server forgets values, client owns materialization. |
| Async tasks | LiveView-parity `assign_async`/`start_async`/`cancel_async`/`handle_async` with `Arbor.AsyncResult`, plus an Arbor `:timeout` extension that kills overdue tasks. |
| Recoverability | Reconnect path: 1:1 transport binding, fresh mount on disconnect, first patch envelope carries full root (BDR-0003). |
| Type safety | Generated Elixir typespecs and TypeScript types from one source of truth (`state do` and `command do`). |
| Observability | Telemetry events for command lifecycle, render, validation, diff, patch, async lifecycle, stream flush. |

### Non-goals

| Non-goal | Reason |
|----------|--------|
| One process per child store | Too much ordering, mailbox, and merge complexity for MVP. |
| CRDT/offline-first | Large complexity increase with no MVP necessity. |
| Event sourcing | Out of scope for the runtime layer. |
| Templated UI composition (HEEx/JSX-style) | Render returns a typed JSON shape; layout belongs to the client. |
| Slot composition | Children are placed by `child(...)`; slots are unnecessary. |
| Built-in PubSub abstraction | Use `Phoenix.PubSub.subscribe/2` directly and `handle_info/2` (BDR-0005). |
| Built-in persistence | Implement via hooks/middleware; no `Arbor.Persistence` behaviour, no bundled adapters (recorded in `spec/backlog.md`). |
| Application-level resync command | Recovery is the reconnect path (BDR-0015). |
| Subtree-replace patch fallback / threshold | Always emit minimal RFC 6902 ops (BDR-0014). |
| Per-child unmount/terminate callback | Mirrors LV LiveComponent (BDR-0012). |
| Server-side stream value retention | Stream values live only on the client after delivery. |
| Async result auto-persistence | No `persist: :ok_only` opt-in. Application implements via hooks if needed. |
| `move`/`copy`/`test` JSON Patch ops | Out of scope. |

## Core Concepts

### Store

A runtime node identified by `(parent_path, module, id)`. The root page store is rooted at `[]`. A store can declare attrs, output state, commands, middleware, streams, async slots, and a render function. Identity persists across re-renders within the same parent; a child whose identity disappears is silently discarded (no callback). The root may define `terminate(reason, ctx)` mirroring `Phoenix.LiveView.terminate/2`.

### `state do` — public output shape

`state do` declares the value `render/1` returns. It is the single source of truth for typespecs, TypeScript codegen, and render-output validation. Field types include primitives, `list(...)`, `map()`, nested `Arbor.State` modules, references to other stores' `state()`, native Elixir typespec unions for variants, `stream(T)` markers (streams/lifecycle), and `AsyncResult.of(T)` markers (async/lifecycle).

```elixir
state do
  field :status, String.t()
  field :items, list(CartItemState.t())
  field :subtotal, MoneyState.t()
  field :error, map() | nil
end
```

Codegen emits both Elixir typespecs and TypeScript:

```ts
export type CartStoreState = {
  status: string
  items: CartItemState[]
  subtotal: MoneyState
  error: Record<string, unknown> | null
}
```

### `ctx.assigns` — single state container

`ctx.assigns` holds both parent-passed values (declared via `attr`) and store-internal values (set in `mount/1` and handlers). There is no `ctx.attrs` namespace (BDR-0010). Function-valued attrs (callbacks) live in `ctx.assigns` like any other value.

### `attr` — compile-time annotation

`attr` declares a parent-supplied assign with type, `required: true | false`, and optional `default:`. The macro is purely compile-time: it drives required-presence checks at the parent's `child(...)` build site, contributes to typespecs and codegen, and produces no runtime namespace. Function-valued attrs declare callbacks:

```elixir
attr :current_user, User.t(), required: true
attr :selected, boolean(), default: false
attr :on_select, function(%{id: String.t()}, any()), required: true
```

### `render/1` and `child(...)`

`render(ctx)` returns a value matching `state do`. Child stores are composed via `child(Module, id: ..., assign_key: value, ...)`, a render-time placeholder that the runtime resolves by mounting/updating the child node and substituting its render output:

```elixir
def render(ctx) do
  %{
    cart: child(CartStore, id: "cart", cart_id: ctx.assigns.cart_id),
    notifications: child(NotificationStore, id: "notifications")
  }
end
```

A child's `id` must be a string; numeric ids must be `to_string/1`'d. Duplicate `(parent_path, module, id)` in one render output raises during reconcile. A child that disappears from `render/1` is unmounted; reappearance produces a fresh mount with no preserved assigns (BDR-0011).

### Command

`command name do payload ... end` declares a client-callable command and its payload schema. Variants in payloads use native typespec unions of literal-tagged maps:

```elixir
command :select_product do
  payload :id, String.t()
end

command :apply_filters do
  payload :status, %{type: :active} | %{type: :paused, value: integer()}
end
```

Codegen emits TypeScript discriminated unions.

### Callbacks

Children invoke parent-provided functions. The mechanism is a function-valued `attr`:

```elixir
attr :on_select, function(%{id: String.t()}, any()), required: true

def handle_command(:select, _, ctx) do
  {:noreply, invoke(ctx, :on_select, %{id: ctx.assigns.product.id})}
end
```

The parent receives the call in `handle_callback/3`:

```elixir
def handle_callback(:product_selected, %{id: id}, ctx) do
  {:noreply, assign(ctx, :selected_product_id, id)}
end
```

### Middleware and `attach_hook`

Per-store `middleware Module` declarations apply only to commands addressed to that node. Cross-cutting concerns attach at runtime via `attach_hook(ctx, id, stage, fun)` (BDR-0004). Stages: `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_render`. Hook return: `{:cont, ctx}`, `{:halt, ctx}`, or `{:halt, reply, ctx}` (only on `:before_command`). Mirrors `Phoenix.LiveView.attach_hook/4`. Each store maintains its own hook table; child-attached hooks see only that node's events. `detach_hook/3` is a silent no-op when the hook is absent.

Schema validation is itself a middleware (`Arbor.Middleware.ValidateCommandSchema`), default-attached but replaceable (BDR-0007). Render-output validation (`Arbor.Middleware.ValidateRender`) is default-on in dev/test, telemetry-only opt-in for prod.

Pipeline order follows declaration / attachment order; the addressed store's `handle_command/3` dispatches after all `:before_command` middleware/hooks have continued; `:after_command` runs after the handler returns; the transport reply is delivered next; the patch push follows; effects fire last (BDR-0009).

### `handle_info/2` — server-side messages

Stores receive arbitrary in-process messages via `handle_info(msg, ctx)`. Typical use: `mount/1` calls `Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")` directly; broadcast messages arrive via `handle_info`. There is no Arbor `subscribe` block, no `handle_broadcast/3` callback, no `broadcast/4` ctx helper (BDR-0005). `handle_info/2` returns `{:noreply, ctx}` only; no transport reply is associated with `handle_info` (it was not triggered by a client command).

### Streams

LiveView-parity stream API for collections that should not live in server memory after delivery. Declaration:

```elixir
stream :messages, dom_id: &"msg-#{&1.id}", limit: -100
```

Operations are ctx-pipe helpers: `stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_dom_id/3`. The full LV option set is supported: `:at`, `:limit`, `:reset`, `:dom_id`, `:update_only`. After flush the runtime retains only the dom_id index; item values are dropped.

Stream-typed fields appear in `state do` as `field :name, stream(T)` and are opaque to JSON Patch. They render as `[]` in the initial-state envelope; subsequent envelopes' `ops` never touch their paths; stream content flows through `stream_ops` only. Cycles with non-empty `stream_ops` always emit an envelope, even when JSON Patch ops are empty (BDR-0018).

Stream reload is application-driven via `ctx |> reload_stream(name)` (BDR-0017). The runtime invokes the store's `reload_stream(name, ctx)` callback to fetch fresh items and emits `reset` + bulk inserts. The runtime never auto-invokes `reload_stream/2`.

### Async tasks

LiveView-parity `assign_async`, `start_async`, `cancel_async`, `handle_async/3`, and `Arbor.AsyncResult`. Plus Arbor extensions:

- `:timeout` option (Arbor extension; LV does not provide one): runtime-side timer kills the task on overdue; produces `failed: {:exit, :timeout}`.
- `[:arbor, :async, ...]` telemetry events: `:start | :stop | :exception | :cancel | :lazy_discard`.
- `handle_async/3` exceptions are caught; runtime survives (BDR-0020 — diverges from BDR-0003 let-it-crash for command/render handlers).

Two patterns:
- `assign_async(ctx, key_or_keys, fun, opts)` writes `Arbor.AsyncResult` to `ctx.assigns` keyed on `key_or_keys`. Supports `:reset` (boolean or subset list).
- `start_async(ctx, name, fun, opts)` spawns a named task; result routes to `handle_async/3`. No automatic AsyncResult assignment (BDR-0019: silent overwrite of the tracked ref + lazy discard for older results).

Cancellation: `cancel_async(ctx, name_or_key, reason)` actively kills the task; `%AsyncResult{}` variant pre-writes failed. Race resolution is first-to-arrive-wins via ref-prune.

Tasks are linked to the runtime; runtime termination kills tasks. Default supervisor: per-runtime `Arbor.AsyncSupervisor`. `:supervisor` opt overrides.

A child store that disappears does not actively cancel its async tasks; results arriving for a no-longer-mounted node are silently discarded (`[:arbor, :async, :lazy_discard]`).

### `stream_async/4`

Composite of async lifecycle and stream API. User fun returns `{:ok, enumerable}`, `{:ok, enumerable, stream_opts}`, or `{:error, reason}`. On success, runtime atomically writes `AsyncResult.ok(prior, true)` to the assign and seeds the stream with the returned items. The state field type is composite: `field :messages, AsyncResult.of(stream(MessageState.t()))`.

`reload_stream` and `stream_async(reset: true)` are complementary recovery paths (BDR-0022): `reload_stream` is silent refresh (no loading flash); `stream_async(reset: true)` re-emits the loading state.

### `Arbor.State` modules

Reusable output-type modules. Not stores: no commands, no `attr`, no lifecycle, no runtime identity. Cannot be referenced via `child(...)`.

```elixir
defmodule MoneyState do
  use Arbor.State

  state do
    field :amount, integer()
    field :currency, String.t()
    field :formatted, String.t()
  end
end
```

A `state do` field whose type is another store's `state()` may be populated by either a `child(Module, id: ...)` placeholder (mounting a child node) or a raw map matching the structural shape (no child mounted). Validation accepts both.

### Field shape edge cases

- Nullable types (`String.t() | nil`) always render the key with `nil` value; the key is never omitted. Wire shape uses JSON `null`.
- Variants are native Elixir typespec unions of literal-tagged maps; codegen produces TypeScript discriminated unions.
- `id` on `child(...)` must be a binary (string).
- Function values never appear in resolved render output; render-output validation rejects them.
- `child/2` is a plain function returning a sentinel; sentinels in render output are resolved, sentinels elsewhere are inert data (no runtime check).

## Architecture Overview

### Core runtime components

| Component | Responsibility |
|-----------|----------------|
| Page Runtime | One GenServer per connected page; owns the store tree, message loop, version counter, transport session. |
| Store Metadata Registry | Compile-time declarations: `attr`, `state`, `command`, `middleware`, `stream`, `async`. |
| Render Resolver | Walks `render/1`'s return value and resolves `child(...)` placeholders bottom-up. |
| Render Validator | Validates each store's resolved output via `Arbor.Middleware.ValidateRender`. |
| Reconciler | Maintains `(parent_path, module, id)` identity; preserves `ctx.assigns` across cycles via reference equality memoization (BDR-0013). |
| Command Router | Resolves `{path, command}` to a node via the store registry; runs schema validation and authorization middleware/hooks; dispatches `handle_command/3`. |
| Middleware Runner | Executes ordered hooks around mount, command, render, terminate. |
| Diff Engine | Produces RFC 6902 JSON Patch ops from previous to next resolved output. Pure structural minimal diff (BDR-0014). |
| Stream Manager | Tracks per-store stream config and dom_id index; accumulates `stream_ops` per cycle; drops values after flush. |
| Async Supervisor | Per-runtime `Task.Supervisor`; tracks refs; routes results to `assign_async` writers, `handle_async/3`, or `stream_async`'s atomic AsyncResult-and-stream update. |
| Transport Adapter | Reference Phoenix Channel adapter; receives commands, sends ref replies, pushes patch envelopes. |
| Codegen | Emits Elixir typespecs and TypeScript types from `state do` and `command do`. |
| Devtools / Trace | Tree shape, last patch, async refs, stream counters, hook timings. |

### Data flow

**Command flow**

```
client command (path + name + payload)
  -> :before_command middleware/hooks (in declaration/attachment order)
  -> schema validation (a middleware)
  -> authorization (a middleware)
  -> handle_command(name, payload, ctx)
  -> :after_command middleware/hooks
  -> transport reply (ok or error category)
  -> patch push (if render output changed or stream ops queued)
  -> effects (broadcasts, etc.)
```

**Server message flow**

```
in-process message (PubSub or otherwise)
  -> :handle_info hooks
  -> handle_info(msg, ctx)
  -> render -> resolve -> validate -> diff -> patch push (if changed)
```

**Async flow**

```
handler calls assign_async/start_async/stream_async
  -> Task spawned under Arbor.AsyncSupervisor
  -> immediate flush of "loading" AsyncResult patch (assign_async/stream_async)
  -> task completes (or times out, crashes, is cancelled)
  -> runtime mailbox receives ref result or :DOWN
  -> ref-prune: if ref still current, route to handle_async/3 or assign_async writer
  -> render -> patch
```

**Reconnect flow**

```
transport drops -> page runtime exits (1:1 binding, BDR-0003)
  -> client reconnects -> fresh page runtime mounts
  -> mount/1 re-runs from scratch
  -> first patch envelope: base_version: 0, version: 1, ops: [{replace, path: "", value: full_root}]
```

### Wire format

| Envelope | Direction | Shape |
|----------|-----------|-------|
| Command | client → server | `{type: "command", path: [...], command: "name", payload: {...}}` (no application sequence number) |
| Reply | server → client | Phoenix Channel ref reply: `{status: "ok" \| "error", payload: {...}}` |
| Patch | server → client | `{type: "patch", base_version, version, ops, stream_ops}` |

`ops` uses RFC 6902 with op types `add | remove | replace` only. `path` values are RFC 6901 JSON Pointer strings. Reorders without `move` op produce per-index `replace` ops; that's accepted as-is. `stream_ops` carry `configure | reset | insert | delete` operations for stream-typed fields. An envelope is emitted whenever `ops` OR `stream_ops` is non-empty (BDR-0018). Empty cycles emit nothing.

Error reply categories on the wire: `unknown_path | unknown_command | invalid_payload | unauthorized | middleware_halt`. Handler-controlled business failures use `{:reply, %{ok: false, error: ...}, ctx}` and arrive on the wire as `status: "ok"`.

## Programming Model and API

### API surface

| Surface | Purpose | Final rule |
|---------|---------|------------|
| `use Arbor.Store` | Marks a module as a store | Required |
| `use Arbor.State` | Marks a module as a reusable state object type | Required for `Arbor.State` modules |
| `attr name, type, opts` | Declares parent-supplied assign (data or function) | Compile-time only; values flow into `ctx.assigns` |
| `state do ... end` | Declares the public output shape | Validated against `render/1` output |
| `field name, type, opts` | One field in `state do` | Supports primitives, lists, nested state, `stream(T)`, `AsyncResult.of(T)`, native typespec unions |
| `command name do payload ... end` | Declares command + payload schema | Runtime-validated |
| `middleware Module` / `middleware {Module, opts}` | Per-store middleware | Runs only for that node's commands |
| `stream name, opts` | Declares stream slot | `:dom_id` (function), `:limit` |
| `async name, opts` | Declares named async slot | Optional sugar over `start_async` |
| `mount(ctx)` | Initialize ctx.assigns | Returns `{:ok, ctx}` |
| `update(new_assigns, ctx)` | React to attr changes | Returns `{:ok, ctx}`; default merges new_assigns |
| `handle_command(name, payload, ctx)` | Client command handler | Returns `{:noreply, ctx}` or `{:reply, payload, ctx}` |
| `handle_callback(name, payload, ctx)` | Upward callback handler | Returns `{:noreply, ctx}` |
| `handle_info(msg, ctx)` | Server-side message handler | Returns `{:noreply, ctx}` |
| `handle_async(name, result, ctx)` | Async task completion handler | Returns `{:noreply, ctx}` |
| `reload_stream(name, ctx)` | Stream reload data source | Returns `{:ok, [item]}` |
| `terminate(reason, ctx)` | Root page store termination | Optional |
| `render(ctx)` | Produce the public output shape | Required |

### `ctx` API

| Function | Purpose |
|----------|---------|
| `assign(ctx, key, value)` / `assign(ctx, kw_or_map)` | Set `ctx.assigns` |
| `update_assign(ctx, key, fun)` | Functionally update an assign |
| `invoke(ctx, callback_name, payload)` | Call a parent-provided function attr |
| `child(Module, opts)` | Render-time placeholder |
| `attach_hook(ctx, id, stage, fun)` | Attach a lifecycle hook |
| `detach_hook(ctx, id, stage)` | Detach a hook (silent no-op if absent) |
| `assign_async(ctx, key_or_keys, fun, opts)` | Spawn async task; AsyncResult writes |
| `start_async(ctx, name, fun, opts)` | Spawn named async task; routes to handle_async |
| `cancel_async(ctx, name_or_key, reason)` | Cancel an in-flight task |
| `stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_dom_id/3` | Stream API (LV-parity) |
| `stream_async(ctx, name, fun, opts)` | Composite async + stream |
| `reload_stream(ctx, name)` | Trigger stream reload via callback |

### Render contract — runtime rules

1. `state do` defines the resolved output shape.
2. `render(ctx)` returns a value structurally matching that shape, with `child(...)` placeholders permitted at any depth where another store's `state()` (or a structurally-equivalent map) is expected.
3. The runtime resolves `child(...)` placeholders bottom-up before validation and diffing.
4. Render-output validation runs per store; default-on in dev/test.
5. JSON Patch is generated from the previous to the next resolved root output.
6. Internal implementation state lives in `ctx.assigns`, the database, async tasks, etc. Only the resolved render output reaches the client.
7. `child(Module, id: ..., ...)` reuses the existing child node when `(parent_path, Module, id)` matches; otherwise a fresh child is mounted. A removed `child(...)` triggers no callback (BDR-0012).
8. `render/1` must be free of observable side effects; the runtime may invoke it more than once per state change.
9. A `render/1` exception terminates the page runtime (let-it-crash, BDR-0003); reconnect mounts fresh.

### Handler contract

`handle_command/3`, `handle_callback/3`, `handle_info/2`, `handle_async/3` return:

- `{:noreply, ctx}` — no reply payload (handle_command emits empty ok reply; others emit no reply at all).
- `{:reply, payload, ctx}` — only valid for `handle_command/3` and root-level `:before_command` hook halts. Other handlers raise on `:reply` returns.

Effects are ctx-pipe helpers (BDR-0006), not effect tuples:

```elixir
def handle_command(:checkout, params, ctx) do
  {:reply, %{order_id: id}, ctx |> assign(:order_id, id)}
end
```

A handler raise in `handle_command/3` or `render/1` terminates the page runtime (BDR-0003). A handler raise in `handle_async/3` is caught and recorded as `[:arbor, :async, :exception]`; the runtime continues (BDR-0020).

### Authorization

Authorization is a middleware/hook that returns `{:halt, {:error, ...}}` to deny commands. The runtime delivers an error reply with `category: "unauthorized"` (BDR-0008). There is no silent-no-op downgrade.

### System commands

Reserved name prefix `arbor:`. User code cannot declare commands under this prefix (compile-time error). System commands flow through the same routing/validation/auth pipeline as user commands.

## Complete Example

### Root page store

```elixir
defmodule MyApp.Stores.ProductPageStore do
  use Arbor.Store

  state do
    field :header, HeaderStore.state()
    field :filters, FilterStore.state()
    field :products, list(ProductCardStore.state())
    field :selected_product_id, String.t() | nil
    field :notifications, NotificationStore.state()
  end

  command :select_product do
    payload :id, String.t()
  end

  command :reload_products do
  end

  middleware Arbor.Middleware.Logger
  middleware Arbor.Middleware.ValidateRender

  def mount(ctx) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "user:#{ctx.assigns.current_user.id}")
    products = Catalog.list_products()
    {:ok,
     ctx
     |> assign(:products, products)
     |> assign(:selected_product_id, nil)
     |> assign(:filters, %{query: "", status: "all"})}
  end

  def handle_command(:select_product, %{id: id}, ctx) do
    {:noreply, assign(ctx, :selected_product_id, id)}
  end

  def handle_command(:reload_products, _, ctx) do
    products = Catalog.list_products(ctx.assigns.filters)
    {:noreply, assign(ctx, :products, products)}
  end

  def handle_callback(:filters_changed, filters, ctx) do
    products = Catalog.list_products(filters)
    {:noreply,
     ctx
     |> assign(:filters, filters)
     |> assign(:products, products)}
  end

  def handle_info({:notification, payload}, ctx) do
    {:noreply, update_assign(ctx, :unread_count, &(&1 + 1))}
  end

  def render(ctx) do
    %{
      header: child(HeaderStore, id: "header", current_user: ctx.assigns.current_user),
      filters: child(FilterStore,
        id: "filters",
        filters: ctx.assigns.filters,
        on_change: fn payload, _ctx -> handle_callback(:filters_changed, payload, ctx) end
      ),
      products:
        for product <- ctx.assigns.products do
          child(ProductCardStore,
            id: product.id,
            product: product,
            selected: product.id == ctx.assigns.selected_product_id
          )
        end,
      selected_product_id: ctx.assigns.selected_product_id,
      notifications: child(NotificationStore, id: "notifications", current_user: ctx.assigns.current_user)
    }
  end
end
```

### Async + stream example

```elixir
defmodule MyApp.Stores.MessagesStore do
  use Arbor.Store

  attr :room_id, :string, required: true

  state do
    field :messages, AsyncResult.of(stream(MessageState.t()))
  end

  stream :messages, dom_id: &"msg-#{&1.id}", limit: -100

  command :reload do
  end

  def mount(ctx) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "room:#{ctx.assigns.room_id}")
    {:ok, stream_async(ctx, :messages, fn -> {:ok, Chat.recent(ctx.assigns.room_id, 50)} end)}
  end

  def handle_command(:reload, _, ctx) do
    {:noreply, reload_stream(ctx, :messages)}
  end

  def handle_info({:message_received, msg}, ctx) do
    {:noreply, stream_insert(ctx, :messages, msg, at: 0, limit: -100)}
  end

  def reload_stream(:messages, ctx), do: {:ok, Chat.recent(ctx.assigns.room_id, 50)}

  def render(_ctx) do
    %{messages: ctx.assigns.messages}
  end
end
```

## Telemetry

| Event | Purpose |
|-------|---------|
| `[:arbor, :command, :start | :stop | :exception]` | Per-command span; metadata: page_id, path, command, status, error_category? |
| `[:arbor, :render, :stop]` | Render duration + node count |
| `[:arbor, :resolve, :stop]` | Placeholder resolution duration + child count |
| `[:arbor, :validate, :stop | :exception]` | Render-output validation result |
| `[:arbor, :diff, :stop]` | Diff duration + op count |
| `[:arbor, :patch, :stop]` | Patch envelope size + op count + stream_op count |
| `[:arbor, :pubsub, :receive]` | (when handle_info dispatches) |
| `[:arbor, :auth, :deny]` | Authorization denials |
| `[:arbor, :async, :start | :stop | :exception | :cancel | :lazy_discard]` | Async task lifecycle |
| `[:arbor, :stream, :flush]` | Stream op flush per cycle |

## Frontend Usage

```ts
const store = arbor.connect<ProductPageStoreState, ProductPageStoreCommands>({
  store: "ProductPageStore",
  params: {}
})

store.subscribe((state) => render(state))

store.command("select_product", { id: "prod_123" })
store.command(["filters"], "change_query", { query: "shirt" })
store.command(["products", "prod_123"], "select", {})
```

Patches arrive as RFC 6902 ops plus `stream_ops`; the client merges into its local copy and dispatches stream ops to maintain stream materializations.

## Generated TypeScript Shape

```ts
export type ProductPageStoreState = {
  header: HeaderStoreState
  filters: FilterStoreState
  products: ProductCardStoreState[]
  selected_product_id: string | null
  notifications: NotificationStoreState
}

export type AsyncResult<T> = {
  loading: unknown | null
  ok: boolean
  result: T | null
  failed: unknown | null
}

export type ProductPageStoreCommands = {
  select_product: { id: string }
  reload_products: {}
}
```

## Delivery Roadmap

| Milestone | Deliverables | Effort | Timeline |
|-----------|--------------|--------|----------|
| M1: Runtime kernel + metadata | Page runtime GenServer; `use Arbor.Store` / `use Arbor.State`; metadata registry for `attr`/`state`/`command`/`middleware`/`subscribe`/`stream`/`async`; `ctx` struct with `assign`/`update_assign`/`invoke`. | High | Weeks 1–2 |
| M2: Render contract + resolver | `child(...)` placeholder, render-output resolver, identity-preserving reconciler, render-output validation middleware, `mount`/`update`/`render` lifecycle, `handle_info/2`, root `terminate/2`. | High | Weeks 3–4 |
| M3: Command pipeline | Path-based routing, payload schema validation middleware, attach_hook/detach_hook, authorization middleware, `handle_command/3`, `handle_callback/3`, transport reply contract, error category enum, system command namespace. | High | Weeks 5–6 |
| M4: Replication + streams | RFC 6902 diff engine, patch envelope (`ops` + `stream_ops`), version counter, stream API (LV-parity: `stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_dom_id/3`), `reload_stream/2`, reference WebSocket adapter. | High | Weeks 7–8 |
| M5: Async lifecycle | `assign_async`, `start_async`, `cancel_async`, `handle_async/3`, `Arbor.AsyncResult`, `Task.Supervisor`, `:timeout` extension, `:reset` (incl subset list), ref-prune races, lazy-discard, `stream_async/4`. | High | Weeks 9–10 |
| M6: Codegen + hardening | Elixir typespec emission, TypeScript codegen for state and command schemas (incl streams, AsyncResult, variants, composite types), telemetry events, devtools, trace buffer, docs, examples, benchmarks. | Medium | Weeks 11–12 |

Persistence is **not** an Arbor primitive (recorded in `spec/backlog.md`). Applications build snapshot save/load using `attach_hook` on `:before_mount` and `:after_command`.

## Acceptance Criteria

The MVP is done when all of the following are true:

- A connected page runs as exactly one runtime process bound 1:1 to its transport session (BDR-0003).
- A store can declare `attr`, `state`, `command`, `middleware`, `stream`, `async`. `attr` is compile-time only; values flow into `ctx.assigns` (BDR-0010).
- `state do` is the public output shape; codegen produces matching Elixir typespecs and TypeScript types.
- `render(ctx)` returns a value matching `state do`, with `child(...)` placeholders permitted; the resolver substitutes them bottom-up.
- Identity is `(parent_path, module, id)`; child assigns survive identity-stable re-renders; disappear-then-reappear is a fresh mount (BDR-0011); `id` must be a string.
- Commands route by `{path, command}`; payload validation, authorization, and arbitrary middleware run in declaration order. Handler returns `{:noreply, ctx}` or `{:reply, payload, ctx}` (BDR-0002).
- Transport reply uses Phoenix Channel ref reply (BDR-0001). Outcome ordering is reply → patch → effects (BDR-0009). Auth failure is hard error (BDR-0008). Wire error categories: `unknown_path | unknown_command | invalid_payload | unauthorized | middleware_halt`.
- `attach_hook/4`, `detach_hook/3` work at any node (root or child) for stages `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_render` (BDR-0004).
- `handle_info(msg, ctx)` shares the runtime mailbox with commands; no Arbor PubSub abstraction (BDR-0005).
- Diff engine emits structural minimal RFC 6902 diff with no threshold (BDR-0014). Initial state is the first patch envelope's `replace` at path `""`.
- No application-level resync command; recovery is reconnect (BDR-0015).
- Stream API LV-parity; server forgets values; reload is application-driven (BDR-0017); stream-only cycles emit envelopes (BDR-0018).
- Async API LV-parity plus an Arbor `:timeout` extension; `start_async` same-name overwrites + lazy-discards (BDR-0019); `handle_async/3` exceptions caught (BDR-0020); telemetry events `[:arbor, :async, :*]` cover the lifecycle.
- `stream_async/4` composite works; `reload_stream` and `stream_async(reset: true)` are complementary (BDR-0022).
- The system runs without CRDTs, offline sync, event sourcing, built-in PubSub, built-in persistence, slot composition, or `move`/`copy`/`test` JSON Patch ops.

## Risks and Trade-offs

| Risk | Mitigation |
|------|------------|
| Single-process page may become a hotspot | Bounded page scope; mailbox/heap telemetry; avoid per-child processes in MVP. |
| Render-output validation cost in prod | Default off in prod (telemetry-only opt-in). |
| Reorders without `move` op produce many ops | Accepted as-is (BDR-0014). Future optimization can add `move` op support if measured. |
| `handle_async/3` divergence from let-it-crash | Documented as BDR-0020; surface via `[:arbor, :async, :exception]`. |
| Stream client drift after disconnect | Reconnect rebuilds full state; `reload_stream/2` covers in-session refresh. |
| Async orphan tasks | Linked to runtime; runtime termination kills tasks; `cancel_async` for explicit. |
| `attr` macro is compile-time but parents pass via `child(...)` | Required-presence check at parent's `child(...)` build site; missing required attr raises during render. |
| TypeScript codegen drift | Codegen runs on every compile in dev; CI check fails build when TS output differs from committed artifacts. |
| Persistence as application pattern, not built-in | Recommend a companion `Arbor.Persistence` library; document hook-based pattern in `docs/persistence-pattern.md` (TBD). |

## Rollback Strategy

If a milestone slips:

1. **First rollback:** ship MVP without the TypeScript codegen step (Elixir typespec only).
2. **Second rollback:** ship without `stream_async/4` (apply `start_async` + manual stream/4).
3. **Third rollback:** ship without `:timeout` async option.
4. **Never rollback:** single-process ownership, attr/assigns unification, child identity rules, command routing, attach_hook, RFC 6902 ops, `handle_info/2`, AsyncResult struct, stream API LV-parity, the BDR set.
