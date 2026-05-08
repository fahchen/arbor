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
| Patch push | A separate transport push delivering JSON Patch operations (and stream operations) caused by a command, an async result, or a `handle_info` message. |
| Transport | The connecting layer (Phoenix Channel over WebSocket) responsible for delivery, ordering, and ref correlation. |
| Hook | A function attached at a specific lifecycle stage on a store node via `attach_hook/4`; analogous to `Phoenix.LiveView.attach_hook/4`. Stages: `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_render`. |
| Middleware | A per-store-node plug-in module declared with the `middleware ...` macro; runs only for commands addressed to that node. |
| Schema validation middleware | A built-in middleware (`Arbor.Middleware.ValidateCommandSchema`) that validates the command payload against the store's `command do payload ... end` declaration. Default-attached but replaceable. |
| Render-output validation middleware | A built-in middleware (`Arbor.Middleware.ValidateRender`) that validates each store's resolved render output against its `state do` declaration. Default-on in dev/test; telemetry-only opt-in for prod. |
| System command | A command name under the reserved `arbor:` prefix, issued by the runtime/client adapter for internal coordination (e.g., `arbor:request_stream_reload`). Not declarable by store authors. |
| `handle_info/2` | Store callback for arbitrary in-process messages (typically delivered by `Phoenix.PubSub.subscribe/2`). Returns `{:noreply, ctx}` only; produces a patch push if `assigns` change. |
| `assigns` | The state map on `ctx`. Holds parent-passed values (declared via `attr`) and store-internal values together; LV-aligned single namespace. |
| `attr` | Compile-time declaration on a store module that names a parent-supplied assign and optionally specifies `required: true`, a typespec, and a `default:` value. Mirrors `Phoenix.Component.attr/3`. Function-valued attrs are how callbacks are passed and declared. |
| `state do` | The compile-time declaration of a store's public render-output shape. Validated by render-output middleware; codegen target for Elixir typespecs and TypeScript. Field types may include primitives, `list(...)`, nested `Arbor.State` modules, nested store `state()` references, native Elixir typespec unions for variants, and field-typed `stream(...)` and `AsyncResult.of(...)` markers (defined in their own features). |
| `child(Module, id: ..., assigns)` | A render-time placeholder. The runtime resolves it into a child store node identified by `(parent_path, Module, id)` and substitutes the child's render output. `child/2` is a plain function returning a sentinel; sentinels found in render output are resolved, sentinels elsewhere are inert data. |
| Resolver | The runtime component that walks the rendered structure, resolves `child(...)` placeholders bottom-up, and produces the final concrete output. |
| `Arbor.State` | Module type for reusable output structures. No lifecycle, no commands, no runtime identity. Cannot be referenced via `child(...)`. |
| Lifecycle | For child stores: `mount(ctx)` and `update(new_assigns, ctx)`, both required to return `{:ok, ctx}`. No per-child unmount/terminate. The root page store may additionally define `terminate(reason, ctx)`. |
| Memoization | A child whose `ctx.assigns` map is reference-equal across render cycles skips its `update/2` and `render/1` invocations and reuses the previously resolved output. |
| `AsyncResult` | A four-field struct (`loading`, `ok?`, `result`, `failed`) carrying the lifecycle of an async-loaded value; serializable through JSON Patch like any other field. Mirrors `Phoenix.LiveView.AsyncResult`. |
