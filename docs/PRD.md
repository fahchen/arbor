# Arbor — PRD and Milestone Plan

This PRD is the authoritative product description for Arbor. The wire-level and runtime contract is fully captured in `spec/` as Gherkin features and `BDR-NNNN` decision records; this document is the narrative that ties those pieces together. Where the spec and PRD disagree, the spec wins.

## Executive Summary

Arbor is a server-authoritative, page-scoped runtime library for Elixir/Phoenix. A single BEAM process per connected page owns a hierarchical tree of stores, routes commands to addressed nodes, computes a structured render output per node, resolves child-store placeholders, validates the resolved output against per-store schemas, diffs it against the previous resolved output, and pushes RFC 6902 JSON Patch updates plus stream-op envelopes to the client. Internal implementation state lives in `socket.assigns` (one map per node, holding both parent-passed values and store-internal state). Only the resolved render output is exposed to the client.

The `state do` declaration is the single source of truth for the wire shape, the Elixir typespec, the TypeScript type, and the render-output validator. The wire transport is Phoenix Channel over WebSocket; commands receive ref-based replies and patches travel as separate channel pushes. The runtime mirrors `Phoenix.LiveView` semantics wherever practical and diverges deliberately when justified (recorded in BDRs).

## Product Definition

### Product statement

Arbor lets developers model page state as a hierarchical tree of stateful stores, hosted in one BEAM process per connected page. Children are composed via explicit `child(...)` placeholders in `to_state/1`, identified by `(parent_path, module, id)`, and live and die with the parent's render output. Cross-cutting concerns (audit, logging, feature flags) attach via `attach_hook/4`, mirroring `Phoenix.LiveView.attach_hook/4`. PubSub is not built in: stores subscribe via `Phoenix.PubSub.subscribe/2` directly and react via `handle_info/2`. Persistence is not built in: applications implement save/load using existing hook and extension points.

### Goals

| Goal | Decision |
|------|----------|
| Single-process consistency | One runtime process per connected page (1:1 with transport). |
| Public/private state split via shape, not namespace | `state do` declares the public render-output shape; `socket.assigns` is the single internal state container (BDR-0010). |
| Render contract | `to_state(socket)` returns a value matching `state do`; `child(...)` placeholders are resolved bottom-up before validation/diffing. |
| Explicit ownership | Parent passes assigns (data + functions) via `child(...)`; child can only mutate its own `socket.assigns`. |
| LV-aligned developer experience | Mount/update/render lifecycle, handle_info for messages, attach_hook for cross-cutting, AsyncResult for async, stream API for collections. |
| Predictable side effects | LV-style `attach_hook` with halting + ordered stages; effects via socket-pipe (BDR-0006). |
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
| Built-in persistence | Implement via hooks; no `Arbor.Persistence` behaviour, no bundled adapters (recorded in `spec/backlog.md`). |
| Application-level resync command | Recovery is the reconnect path (BDR-0015). |
| Subtree-replace patch fallback / threshold | Always emit minimal RFC 6902 ops (BDR-0014). |
| Per-child unmount/terminate callback | Mirrors LV LiveComponent (BDR-0012). |
| Server-side stream value retention | Stream values live only on the client after delivery. |
| Async result auto-persistence | No `persist: :ok_only` opt-in. Application implements via hooks if needed. |
| `move`/`copy`/`test` JSON Patch ops | Out of scope. |

## Core Concepts

### Store

A runtime node identified by `(parent_path, module, id)`. The root page store is rooted at `[]`. A store can declare attrs, output state, commands, streams, async slots, and a render function. Cross-cutting and per-node concerns (auth, validation, logging, tracing) attach at runtime via `attach_hook(socket, ...)` inside `mount/1` or any handler — there is no `middleware` macro (BDR-0004). Identity persists across re-renders within the same parent; a child whose identity disappears is silently discarded (no callback). The root may define `terminate(reason, socket)` mirroring `Phoenix.LiveView.terminate/2`.

### `state do` — public output shape

`state do` declares the value `to_state/1` returns. It is the single source of truth for typespecs, TypeScript codegen, and render-output validation. Field types include primitives, `list(...)`, `map()`, nested `Arbor.State` modules, references to other stores' `state()`, native Elixir typespec unions for variants, `stream(T)` markers (streams/lifecycle), and `AsyncResult.of(T)` markers (async/lifecycle).

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

### Socket fields

Arbor's `socket` mirrors [`Phoenix.Socket`](https://hexdocs.pm/phoenix/1.8.7/Phoenix.Socket.html#module-socket-fields)'s shape so handlers, hooks, and helpers all read the same struct.

| Field | Type | Purpose |
|-------|------|---------|
| `assigns` | `map()` | Single state container. Parent-supplied values (declared via `attr`) and store-internal values (set in `mount/1` and handlers) live together. The only field `to_state/1` reads from. There is no `socket.attrs` namespace (BDR-0010). Function-valued attrs live here like any other value. |
| `id` | `String.t()` | The store node's id within its parent (second component of the identity tuple). |
| `parent_path` | `[atom() \| String.t()]` | Ordered path from the root to this node's parent. Combined with `module` and `id` forms the runtime identity used for memoization and command routing. |
| `module` | `module()` | The store module owning this node. Read-only. |
| `endpoint`, `topic`, `transport_pid` | Phoenix Channel scaffolding | Provided so hooks and helpers can broadcast or push outside the standard envelope flow when needed. Read-only. |
| `private` | `map()` | Reserved for runtime bookkeeping (hook table, async ref tracking, pending stream ops). Do not read or write directly; use the corresponding helpers. |

Helpers like `assign/2,3`, `update_assign/3`, `attach_hook/4`, `stream/4`, `assign_async/3,4`, `start_async/3,4`, `cancel_async/2,3`, and `stream_async/4` all take a socket as the first argument and return a new socket — chainable with `|>`.

### `attr` — compile-time annotation

`attr` declares a parent-supplied assign with type, `required: true | false`, and optional `default:`. The macro is purely compile-time: it drives required-presence checks at the parent's `child(...)` build site, contributes to typespecs and codegen, and produces no runtime namespace. Function-valued attrs declare callbacks:

```elixir
attr :current_user, User.t(), required: true
attr :selected, boolean(), default: false
attr :on_select, (%{id: String.t()} -> any()), required: true
```

### `to_state/1` and `child(...)`

`to_state(socket)` returns a value matching `state do`. Child stores are composed via `child(Module, id: ..., assign_key: value, ...)`, a render-time placeholder that the runtime resolves by mounting/updating the child node and substituting its render output:

```elixir
def to_state(socket) do
  %{
    cart: child(CartStore, id: "cart", cart_id: socket.assigns.cart_id),
    notifications: child(NotificationStore, id: "notifications")
  }
end
```

A child's `id` must be a string; numeric ids must be `to_string/1`'d. Duplicate `(parent_path, module, id)` in one render output raises during reconcile. A child that disappears from `to_state/1` is unmounted; reappearance produces a fresh mount with no preserved assigns (BDR-0011).

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
attr :on_select, (%{id: String.t()} -> any()), required: true

def handle_command(:select, _, socket) do
  {:noreply, invoke(socket, :on_select, %{id: socket.assigns.product.id})}
end
```

The parent supplies the closure inline through `child(...)`. The closure runs in the parent's lexical scope, so it can update parent state directly. There is no separate `handle_callback` dispatcher:

```elixir
child(ProductCardStore,
  id: product.id,
  product: product,
  on_select: fn %{id: id} ->
    # runs in the parent's frame; mutates parent state through closure
    send(self(), {:product_selected, id})
  end
)
```

### `attach_hook` — sole extension primitive

All cross-cutting and per-node concerns use `attach_hook(socket, id, stage, fun)` (BDR-0004). There is no `middleware` macro. Stages: `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_to_state`. Hook return: `{:cont, socket}`, `{:halt, socket}`, or `{:halt, reply, socket}` (only on `:before_command`). Mirrors `Phoenix.LiveView.attach_hook/4`. Each store maintains its own hook table; child-attached hooks see only that node's events. `detach_hook/3` is a silent no-op when the hook is absent.

Authors attach hooks inside `mount/1` for stable concerns and inside any handler for runtime-driven attachment. Built-in hooks (`Arbor.Hooks.ValidateCommandSchema` on `:before_command`, `Arbor.Hooks.ValidateToState` on `:after_to_state`) are attached by the runtime's mount path; authors may detach or replace them (BDR-0007). Render-output validation is default-on in dev/test, telemetry-only opt-in for prod.

Pipeline order follows hook attachment order; the addressed store's `handle_command/3` dispatches after all `:before_command` hooks have continued; `:after_command` runs after the handler returns; the transport reply is delivered next; the patch push follows; effects fire last (BDR-0009).

### `handle_info/2` — server-side messages

Stores receive arbitrary in-process messages via `handle_info(msg, socket)`. Typical use: `mount/1` calls `Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")` directly; broadcast messages arrive via `handle_info`. There is no Arbor `subscribe` block, no `handle_broadcast/3` callback, no `broadcast/4` socket helper (BDR-0005). `handle_info/2` returns `{:noreply, socket}` only; no transport reply is associated with `handle_info` (it was not triggered by a client command).

### Streams

LiveView-parity stream API for collections that should not live in server memory after delivery. Declaration:

```elixir
stream :messages, item_key: &"msg-#{&1.id}", limit: -100
```

Operations are socket-pipe helpers: `stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_item_key/3`. The full LV option set is supported: `:at`, `:limit`, `:reset`, `:item_key`, `:update_only`. After flush the runtime retains only the item_key index; item values are dropped.

Stream-typed fields appear in `state do` as `field :name, stream(T)` and are opaque to JSON Patch. They render as `[]` in the initial-state envelope; subsequent envelopes' `ops` never touch their paths; stream content flows through `stream_ops` only. Cycles with non-empty `stream_ops` always emit an envelope, even when JSON Patch ops are empty (BDR-0018).

There is no dedicated reload mechanism. To refresh a stream the application calls `stream(socket, name, fresh_items, reset: true)` directly (the runtime emits a `reset` op followed by per-item inserts in the same envelope). When the refresh involves an async fetch, use `stream_async(socket, name, fun, reset: true)` — see below for the loading-flash variant (BDR-0022).

### Async tasks

LiveView-parity `assign_async`, `start_async`, `cancel_async`, `handle_async/3`, and `Arbor.AsyncResult`. Plus Arbor extensions:

- `:timeout` option (Arbor extension; LV does not provide one): runtime-side timer kills the task on overdue; produces `failed: {:exit, :timeout}`.
- `[:arbor, :async, ...]` telemetry events: `:start | :stop | :exception | :cancel | :lazy_discard`.
- `handle_async/3` exceptions are caught; runtime survives (BDR-0020 — diverges from BDR-0003 let-it-crash for command/render handlers).

Two patterns:
- `assign_async(socket, key_or_keys, fun, opts)` writes `Arbor.AsyncResult` to `socket.assigns` keyed on `key_or_keys`. Supports `:reset` (boolean or subset list).
- `start_async(socket, name, fun, opts)` spawns a named task; result routes to `handle_async/3`. No automatic AsyncResult assignment (BDR-0019: silent overwrite of the tracked ref + lazy discard for older results).

Cancellation: `cancel_async(socket, name_or_key, reason)` actively kills the task; `%AsyncResult{}` variant pre-writes failed. Race resolution is first-to-arrive-wins via ref-prune.

Tasks are linked to the runtime; runtime termination kills tasks. Default supervisor: per-runtime `Arbor.AsyncSupervisor`. `:supervisor` opt overrides.

A child store that disappears does not actively cancel its async tasks; results arriving for a no-longer-mounted node are silently discarded (`[:arbor, :async, :lazy_discard]`).

### `stream_async/4`

Composite of async lifecycle and stream API. User fun returns `{:ok, enumerable}`, `{:ok, enumerable, stream_opts}`, or `{:error, reason}`. On success, runtime atomically writes `AsyncResult.ok(prior, true)` to the assign and seeds the stream with the returned items. The state field type is composite: `field :messages, AsyncResult.of(stream(MessageState.t()))`.

Refresh paths (BDR-0022): silent refresh uses `stream(reset: true)` with items already in hand; loading-flash refresh uses `stream_async(reset: true)` to re-run an async fetch and re-emit the AsyncResult `:loading` state until the new result arrives.

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
| Store Metadata Registry | Compile-time declarations: `attr`, `state`, `command`, `stream`, `async`. |
| Render Resolver | Walks `to_state/1`'s return value and resolves `child(...)` placeholders bottom-up. |
| Render Validator | Validates each store's resolved output via `Arbor.Hooks.ValidateToState`. |
| Reconciler | Maintains `(parent_path, module, id)` identity; preserves `socket.assigns` across cycles via reference equality memoization (BDR-0013). |
| Command Router | Resolves `{path, command}` to a node via the store registry; runs schema validation and authorization hooks; dispatches `handle_command/3`. |
| Hook Runner | Executes ordered hooks around mount, command, render, terminate. |
| Diff Engine | Produces RFC 6902 JSON Patch ops from previous to next resolved output. Pure structural minimal diff (BDR-0014). |
| Stream Manager | Tracks per-store stream config and item_key index; accumulates `stream_ops` per cycle; drops values after flush. |
| Async Supervisor | Per-runtime `Task.Supervisor`; tracks refs; routes results to `assign_async` writers, `handle_async/3`, or `stream_async`'s atomic AsyncResult-and-stream update. |
| Transport Adapter | Reference Phoenix Channel adapter; receives commands, sends ref replies, pushes patch envelopes. |
| Codegen | Emits Elixir typespecs and TypeScript types from `state do` and `command do`. |
| Devtools / Trace | Tree shape, last patch, async refs, stream counters, hook timings. |

### Data flow

**Command flow**

```
client command (path + name + payload)
  -> :before_command hooks (in attachment order; includes built-in
     ValidateCommandSchema and any author-attached authorization hook)
  -> handle_command(name, payload, socket)
  -> :after_command hooks
  -> transport reply (ok or error category)
  -> patch push (if render output changed or stream ops queued)
  -> effects (broadcasts, etc.)
```

**Server message flow**

```
in-process message (PubSub or otherwise)
  -> :handle_info hooks
  -> handle_info(msg, socket)
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

There is no wire enum of error categories. Malformed or impossible commands (unknown path, undeclared command, schema-failing payload) raise inside the runtime; the page process exits per let-it-crash; the transport drops; the client reconnects (mirrors LV's `phx-event` semantics). Graceful denials and business failures travel as `{:halt, payload, socket}` from a hook or `{:reply, payload, socket}` from a handler — both arrive on the wire with channel status `:ok` and the application inspects the payload (e.g., an `ok: false` flag) to distinguish.

## Programming Model and API

### API surface

| Surface | Purpose | Final rule |
|---------|---------|------------|
| `use Arbor.Store` | Marks a module as a store | Required |
| `use Arbor.State` | Marks a module as a reusable state object type | Required for `Arbor.State` modules |
| `attr name, type, opts` | Declares parent-supplied assign (data or function) | Compile-time only; values flow into `socket.assigns` |
| `state do ... end` | Declares the public output shape | Validated against `to_state/1` output |
| `field name, type, opts` | One field in `state do` | Supports primitives, lists, nested state, `stream(T)`, `AsyncResult.of(T)`, native typespec unions |
| `command name do payload ... end` | Declares command + payload schema | Runtime-validated |
| `attach_hook(socket, id, stage, fun)` | Attach a lifecycle hook on a store node | Sole extension primitive (BDR-0004); replaces the prior `middleware` macro |
| `detach_hook(socket, id, stage)` | Remove a previously-attached hook | Silent no-op when absent |
| `stream name, opts` | Declares stream slot | `:item_key` (function), `:limit` |
| `async name, opts` | Declares named async slot | Optional sugar over `start_async` |
| `mount(socket)` | Initialize socket.assigns | Returns `{:ok, socket}` |
| `update(new_assigns, socket)` | React to attr changes | Returns `{:ok, socket}`; default merges new_assigns |
| `handle_command(name, payload, socket)` | Client command handler | Returns `{:noreply, socket}` or `{:reply, payload, socket}` |
| `handle_info(msg, socket)` | Server-side message handler (also receives upward callback effects via `send/2`) | Returns `{:noreply, socket}` |
| `handle_async(name, result, socket)` | Async task completion handler | Returns `{:noreply, socket}` |
| `terminate(reason, socket)` | Root page store termination | Optional |
| `to_state(socket)` | Produce the public output shape | Required |

### `socket` API

| Function | Purpose |
|----------|---------|
| `assign(socket, key, value)` / `assign(socket, kw_or_map)` | Set `socket.assigns` |
| `update_assign(socket, key, fun)` | Functionally update an assign |
| `invoke(socket, callback_name, payload)` | Call a parent-provided function attr |
| `child(Module, opts)` | Render-time placeholder |
| `attach_hook(socket, id, stage, fun)` | Attach a lifecycle hook |
| `detach_hook(socket, id, stage)` | Detach a hook (silent no-op if absent) |
| `assign_async(socket, key_or_keys, fun, opts)` | Spawn async task; AsyncResult writes |
| `start_async(socket, name, fun, opts)` | Spawn named async task; routes to handle_async |
| `cancel_async(socket, name_or_key, reason)` | Cancel an in-flight task |
| `stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_item_key/3` | Stream API (LV-parity) |
| `stream_async(socket, name, fun, opts)` | Composite async + stream |

### Render contract — runtime rules

1. `state do` defines the resolved output shape.
2. `to_state(socket)` returns a value structurally matching that shape, with `child(...)` placeholders permitted at any depth where another store's `state()` (or a structurally-equivalent map) is expected.
3. The runtime resolves `child(...)` placeholders bottom-up before validation and diffing.
4. Render-output validation runs per store; default-on in dev/test.
5. JSON Patch is generated from the previous to the next resolved root output.
6. Internal implementation state lives in `socket.assigns`, the database, async tasks, etc. Only the resolved render output reaches the client.
7. `child(Module, id: ..., ...)` reuses the existing child node when `(parent_path, Module, id)` matches; otherwise a fresh child is mounted. A removed `child(...)` triggers no callback (BDR-0012).
8. `to_state/1` must be free of observable side effects; the runtime may invoke it more than once per state change.
9. A `to_state/1` exception terminates the page runtime (let-it-crash, BDR-0003); reconnect mounts fresh.

### Handler contract

`handle_command/3`, `handle_info/2`, `handle_async/3` return:

- `{:noreply, socket}` — no reply payload (handle_command emits empty ok reply; others emit no reply at all).
- `{:reply, payload, socket}` — only valid for `handle_command/3` and root-level `:before_command` hook halts. Other handlers raise on `:reply` returns.

Effects are socket-pipe helpers (BDR-0006), not effect tuples:

```elixir
def handle_command(:checkout, params, socket) do
  {:reply, %{order_id: id}, socket |> assign(:order_id, id)}
end
```

A handler raise in `handle_command/3` or `to_state/1` terminates the page runtime (BDR-0003). A handler raise in `handle_async/3` is caught and recorded as `[:arbor, :async, :exception]`; the runtime continues (BDR-0020).

### Authorization

Authorization is a `:before_command` hook that returns `{:halt, %{ok: false, reason: "unauthorized", ...}, socket}` to deny a command. The transport reply has channel status `:ok` and the payload carries the explicit denial flag (BDR-0008). There is no silent-ok downgrade and no wire-level error category — denials are graceful business outcomes, while malformed commands let the runtime crash.

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

  command :reload_products

  def mount(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "user:#{socket.assigns.current_user.id}")
    products = Catalog.list_products()
    {:ok,
     socket
     |> attach_hook(:logger, :before_command, &Arbor.Hooks.Logger.log/4)
     |> assign(:products, products)
     |> assign(:selected_product_id, nil)
     |> assign(:filters, %{query: "", status: "all"})}
  end

  def handle_command(:select_product, %{id: id}, socket) do
    {:noreply, assign(socket, :selected_product_id, id)}
  end

  def handle_command(:reload_products, _, socket) do
    products = Catalog.list_products(socket.assigns.filters)
    {:noreply, assign(socket, :products, products)}
  end

  def handle_info({:filters_changed, filters}, socket) do
    products = Catalog.list_products(filters)
    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:products, products)}
  end

  def handle_info({:notification, _payload}, socket) do
    {:noreply, update_assign(socket, :unread_count, &(&1 + 1))}
  end

  def to_state(socket) do
    %{
      header: child(HeaderStore, id: "header", current_user: socket.assigns.current_user),
      filters: child(FilterStore,
        id: "filters",
        filters: socket.assigns.filters,
        on_change: fn payload -> send(self(), {:filters_changed, payload}) end
      ),
      products:
        for product <- socket.assigns.products do
          child(ProductCardStore,
            id: product.id,
            product: product,
            selected: product.id == socket.assigns.selected_product_id
          )
        end,
      selected_product_id: socket.assigns.selected_product_id,
      notifications: child(NotificationStore, id: "notifications", current_user: socket.assigns.current_user)
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

  stream :messages, item_key: &"msg-#{&1.id}", limit: -100

  command :reload

  def mount(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "room:#{socket.assigns.room_id}")
    {:ok, stream_async(socket, :messages, fn -> {:ok, Chat.recent(socket.assigns.room_id, 50)} end)}
  end

  def handle_command(:reload, _, socket) do
    items = Chat.recent(socket.assigns.room_id, 50)
    {:noreply, stream(socket, :messages, items, reset: true)}
  end

  def handle_info({:message_received, msg}, socket) do
    {:noreply, stream_insert(socket, :messages, msg, at: 0, limit: -100)}
  end

  def to_state(socket) do
    %{messages: socket.assigns.messages}
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

export type AsyncResult<T> =
  | { status: "loading"; result: T | null; reason: null }
  | { status: "ok"; result: T; reason: null }
  | { status: "failed"; result: T | null; reason: unknown }

export type ProductPageStoreCommands = {
  select_product: { id: string }
  reload_products: {}
}
```

## Delivery Roadmap

| Milestone | Deliverables | Effort | Timeline |
|-----------|--------------|--------|----------|
| M1: Runtime kernel + metadata | Page runtime GenServer; `use Arbor.Store` / `use Arbor.State`; metadata registry for `attr`/`state`/`command`/`stream`/`async`; `socket` struct with `assign`/`update_assign`/`invoke`/`attach_hook`/`detach_hook`. | High | Weeks 1–2 |
| M2: Render contract + resolver | `child(...)` placeholder, render-output resolver, identity-preserving reconciler, render-output validation hook, `mount`/`update`/`render` lifecycle, `handle_info/2`, root `terminate/2`. | High | Weeks 3–4 |
| M3: Command pipeline | Path-based routing, payload schema validation hook, attach_hook/detach_hook, authorization hook, `handle_command/3`, transport reply contract, let-it-crash for malformed commands, system command namespace. | High | Weeks 5–6 |
| M4: Replication + streams | RFC 6902 diff engine, patch envelope (`ops` + `stream_ops`), version counter, stream API (LV-parity: `stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_item_key/3`), reference WebSocket adapter. | High | Weeks 7–8 |
| M5: Async lifecycle | `assign_async`, `start_async`, `cancel_async`, `handle_async/3`, `Arbor.AsyncResult`, `Task.Supervisor`, `:timeout` extension, `:reset` (incl subset list), ref-prune races, lazy-discard, `stream_async/4`. | High | Weeks 9–10 |
| M6: Codegen + hardening | Elixir typespec emission, TypeScript codegen for state and command schemas (incl streams, AsyncResult, variants, composite types), telemetry events, devtools, trace buffer, docs, examples, benchmarks. | Medium | Weeks 11–12 |

Persistence is **not** an Arbor primitive (recorded in `spec/backlog.md`). Applications load snapshots inside their own `mount/1` body and save via `attach_hook` on `:after_command`. Valid hook stages: `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_to_state`.

## Acceptance Criteria

The MVP is done when all of the following are true:

- A connected page runs as exactly one runtime process bound 1:1 to its transport session (BDR-0003).
- A store can declare `attr`, `state`, `command`, `stream`, `async`. `attr` is compile-time only; values flow into `socket.assigns` (BDR-0010). Hooks are runtime-attached via `attach_hook` (BDR-0004); there is no `middleware` macro.
- `state do` is the public output shape; codegen produces matching Elixir typespecs and TypeScript types.
- `to_state(socket)` returns a value matching `state do`, with `child(...)` placeholders permitted; the resolver substitutes them bottom-up.
- Identity is `(parent_path, module, id)`; child assigns survive identity-stable re-renders; disappear-then-reappear is a fresh mount (BDR-0011); `id` must be a string.
- Commands route by `{path, command}`; payload validation, authorization, and arbitrary `:before_command` hooks run in attachment order. Handler returns `{:noreply, socket}` or `{:reply, payload, socket}` (BDR-0002).
- Transport reply uses Phoenix Channel ref reply (BDR-0001). Outcome ordering is reply → patch → effects (BDR-0009). Malformed or impossible commands crash the page runtime per let-it-crash (LV-aligned); graceful denials use `{:halt, payload, socket}` with channel status `:ok` (BDR-0008).
- `attach_hook/4`, `detach_hook/3` work at any node (root or child) for stages `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_to_state` (BDR-0004).
- `handle_info(msg, socket)` shares the runtime mailbox with commands; no Arbor PubSub abstraction (BDR-0005).
- Diff engine emits structural minimal RFC 6902 diff with no threshold (BDR-0014). Initial state is the first patch envelope's `replace` at path `""`.
- No application-level resync command; recovery is reconnect (BDR-0015).
- Stream API LV-parity; server forgets values; reload is application-driven (BDR-0017); stream-only cycles emit envelopes (BDR-0018).
- Async API LV-parity plus an Arbor `:timeout` extension; `start_async` same-name overwrites + lazy-discards (BDR-0019); `handle_async/3` exceptions caught (BDR-0020); telemetry events `[:arbor, :async, :*]` cover the lifecycle.
- `stream_async/4` composite works; `stream(reset: true)` and `stream_async(reset: true)` cover silent and loading-flash refresh respectively (BDR-0022).
- The system runs without CRDTs, offline sync, event sourcing, built-in PubSub, built-in persistence, slot composition, or `move`/`copy`/`test` JSON Patch ops.

## Risks and Trade-offs

| Risk | Mitigation |
|------|------------|
| Single-process page may become a hotspot | Bounded page scope; mailbox/heap telemetry; avoid per-child processes in MVP. |
| Render-output validation cost in prod | Default off in prod (telemetry-only opt-in). |
| Reorders without `move` op produce many ops | Accepted as-is (BDR-0014). Future optimization can add `move` op support if measured. |
| `handle_async/3` divergence from let-it-crash | Documented as BDR-0020; surface via `[:arbor, :async, :exception]`. |
| Stream client drift after disconnect | Reconnect rebuilds full state; `stream(reset: true)` covers in-session refresh. |
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
