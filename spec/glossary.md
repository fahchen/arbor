# Glossary

Shared domain terminology for Arbor specifications.

| Term | Definition |
|------|------------|
| Page runtime | The BEAM process owning the store tree for one connected client session. |
| Store node | A runtime instance of a store module, identified by `(parent_path, module, id)`. |
| Store registry | The runtime-internal table of currently mounted store nodes, updated after each render+reconcile cycle and consulted for path resolution. |
| Path | An ordered list of segments that walks the resolved render output from the root store down to a child store. |
| Identity | The tuple `(parent_path, module, id)` that names a child store node within its parent. The `id` is constrained to a binary (string). |
| Command envelope | The wire shape carrying `path`, `command`, and `payload` (no application-layer sequence number). |
| Reply | The transport-level (Phoenix Channel ref-based) response to a command push; carries `status: "ok" \| "error"` and a `payload` map. |
| Patch push | A separate transport push delivering one patch envelope. |
| Patch envelope | The wire shape `{type: "patch", base_version, version, ops, stream_ops}`. `ops` is an RFC 6902 array (`add`/`remove`/`replace` only). `stream_ops` is defined by streams/lifecycle. `version` is the post-application monotonic counter; `base_version` is `version - 1`. |
| Diff engine | Runtime component that compares the previous and next resolved root render output and emits the structural minimal sequence of RFC 6902 ops. No threshold, no subtree-replace fallback, no special-case array strategy. |
| JSON Pointer | RFC 6901 string syntax used for `path` values in JSON Patch ops; runtime relies on a library for encoding (including `~0`/`~1` escapes). |
| Version counter | Monotonic integer per page runtime starting at `0` and incrementing per emitted patch envelope. Resets on reconnect (fresh runtime starts at 0). |
| Initial state delivery | First patch envelope after a fresh mount carries `base_version: 0, version: 1, ops: [{op: "replace", path: "", value: <full root>}]`. No separate "snapshot" envelope type. |
| Transport | The connecting layer (Phoenix Channel over WebSocket) responsible for delivery, ordering, and ref correlation. |
| Hook | A function attached at a specific lifecycle stage on a store node via `attach_hook/4`; analogous to `Phoenix.LiveView.attach_hook/4`. Stages: `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_render`. The sole extension primitive — Arbor has no `middleware` macro (see BDR-0004). |
| Schema validation hook | A built-in hook (`Arbor.Hooks.ValidateCommandSchema`) attached on `:before_command` by the runtime's mount path. Validates the command payload against the store's `command do payload ... end` declaration. Default-attached but detachable / replaceable. |
| Render-output validation hook | A built-in hook (`Arbor.Hooks.ValidateRender`) attached on `:after_render` by the runtime's mount path. Validates each store's resolved render output against its `state do` declaration. Default-on in dev/test; telemetry-only opt-in for prod. |
| System command | A command name under the reserved `arbor:` prefix, issued by the runtime/client adapter for internal coordination (e.g., `arbor:request_stream_reload`). Not declarable by store authors. |
| `handle_info/2` | Store callback for arbitrary in-process messages (typically delivered by `Phoenix.PubSub.subscribe/2`). Returns `{:noreply, ctx}` only; produces a patch push if `assigns` change. |
| `assigns` | The state map on `ctx`. Holds parent-passed values (declared via `attr`) and store-internal values together; LV-aligned single namespace. |
| `attr` | Compile-time declaration on a store module that names a parent-supplied assign and optionally specifies `required: true`, a typespec, and a `default:` value. Mirrors `Phoenix.Component.attr/3`. Function-valued attrs are how callbacks are passed and declared. |
| `state do` | The compile-time declaration of a store's public render-output shape. Validated by the render-output validation hook; codegen target for Elixir typespecs and TypeScript. Field types may include primitives, `list(...)`, nested `Arbor.State` modules, nested store `state()` references, native Elixir typespec unions for variants, and field-typed `stream(...)` and `AsyncResult.of(...)` markers (defined in their own features). |
| `child(Module, id: ..., assigns)` | A render-time placeholder. The runtime resolves it into a child store node identified by `(parent_path, Module, id)` and substitutes the child's render output. `child/2` is a plain function returning a sentinel; sentinels found in render output are resolved, sentinels elsewhere are inert data. |
| Resolver | The runtime component that walks the rendered structure, resolves `child(...)` placeholders bottom-up, and produces the final concrete output. |
| `Arbor.State` | Module type for reusable output structures. No lifecycle, no commands, no runtime identity. Cannot be referenced via `child(...)`. |
| Lifecycle | For child stores: `mount(ctx)` and `update(new_assigns, ctx)`, both required to return `{:ok, ctx}`. No per-child unmount/terminate. The root page store may additionally define `terminate(reason, ctx)`. |
| Memoization | A child whose `ctx.assigns` map is reference-equal across render cycles skips its `update/2` and `render/1` invocations and reuses the previously resolved output. |
| `AsyncResult` | A four-field struct (`loading`, `ok?`, `result`, `failed`) carrying the lifecycle of an async-loaded value; serializable through JSON Patch like any other field. Mirrors `Phoenix.LiveView.AsyncResult`. |
| Stream slot | A named stream owned by one store, with metadata (`:item_key` function, `:limit`) and a server-side item_key index. Declared via `stream :name, opts`. |
| Item key | A binary identifier per stream item that the client uses to identify the item in its local materialization. Defaults to `"#{stream_name}-#{item.id}"`. |
| Stream op | One entry in the envelope's `stream_ops` array: `configure`, `reset`, `insert`, or `delete`. Inserts carry `item_key`, `at`, `limit`, `update_only`, `data`. Deletes carry `item_key`. |
| Pending stream ops | Ops accumulated by handler calls that have not yet been flushed to the wire. Flushed once per handler invocation; never carried across handlers. |
| `reload_stream/2` | Store callback returning `{:ok, [item]}` for stream recovery. Invoked only when the application explicitly calls `ctx \|> reload_stream(name)`. The runtime never auto-invokes it. |
| `Arbor.AsyncSupervisor` | A per-runtime `Task.Supervisor` started alongside the page runtime; the default supervisor for `assign_async/start_async` tasks. The `:supervisor` option overrides. |
| Lazy discard | Runtime convention of letting an async task complete and dropping its result if the originating store node has since disappeared from the tree. Surfaces as `[:arbor, :async, :lazy_discard]` telemetry. |
| `AsyncResult.of(T)` | Compile-time typespec marker for `state do` fields. Produces an Elixir typespec and TypeScript type matching the four-field AsyncResult shape parameterized on `T`. `T` may be any state field type, including composites like `stream(MessageState.t())` (used by `stream_async/4`'s composite slot — see streams/lifecycle and async/stream-async features). No runtime helper named `of/1`; runtime construction uses `Arbor.AsyncResult.loading/0,1,2`, `ok/2`, `failed/2`. |
| Ref-prune | Mechanism by which the runtime discards stale async results: each task is tracked by its monitor ref; on result delivery, if the stored ref no longer matches (because of overwrite, cancel, or lazy-discard), the result is rejected. Mirrors `Phoenix.LiveView.Async.prune_current_async/3`. |
| `stream_async/4` | Composite async-and-stream API: spawns a task, holds an `AsyncResult` in `ctx.assigns.<name>` for client-visible loading state, and on success seeds the named stream slot with the returned items. The AsyncResult's `result` field is `true` on success — items live in the stream, not the AsyncResult. |
| `invoke(ctx, callback_name, payload)` | Child-side helper that calls the parent-supplied function attr stored at `ctx.assigns.<callback_name>` with `payload` as the single argument. The function's return value replaces `ctx` (the parent's `handle_callback/3` returns a new ctx that flows back as the child's updated ctx for the rest of the handler). |
| `handle_callback(name, payload, ctx)` | Parent-side store callback that receives upward callback invocations from a child. Returns `{:noreply, ctx}`. Wired up by passing the parent's `handle_callback`-bound function to the child via `child(Module, id: ..., on_x: fn payload -> handle_callback(:x, payload, ctx) end)` (or via a runtime helper that produces the same closure). |
| `update_assign(ctx, key, fun)` | Functionally update one assign by passing the existing value through `fun`. Equivalent to `assign(ctx, key, fun.(ctx.assigns[key]))`. |
| Wire AsyncResult shape | The Elixir struct field `ok?` is serialized as `ok` (no `?`) on the wire. JSON wire shape: `{"loading": ..., "ok": <bool>, "result": ..., "failed": ...}`. The TypeScript codegen target uses the wire-shape names. |
