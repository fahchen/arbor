# Glossary

Shared domain terminology for Arbor specifications.

| Term | Definition |
|------|------------|
| Page runtime | The BEAM process owning the store tree for one connected client session. |
| Store node | A runtime instance of a store module, identified by `(parent_path, module, id)`. |
| Store registry | The runtime-internal table of currently mounted store nodes, updated after each render+reconcile cycle and consulted for path resolution. |
| Path | An ordered list of segments that walks the resolved render output from the root store down to a child store. |
| Command envelope | The wire shape carrying `path`, `command`, and `payload` (no application-layer sequence number). |
| Reply | The transport-level (Phoenix Channel ref-based) response to a command push; carries `status: "ok" \| "error"` and a `payload` map. |
| Patch push | A separate transport push delivering JSON Patch operations (and stream operations) caused by a command, an async result, or a `handle_info` message. |
| Transport | The connecting layer (Phoenix Channel over WebSocket) responsible for delivery, ordering, and ref correlation. |
| Hook | A function attached at a specific lifecycle stage on a store node via `attach_hook/4`; analogous to `Phoenix.LiveView.attach_hook/4`. Stages: `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_render`. |
| Middleware | A per-store-node plug-in module declared with the `middleware ...` macro; runs only for commands addressed to that node. |
| Schema validation middleware | A built-in middleware (`Arbor.Middleware.ValidateCommandSchema`) that validates the command payload against the store's `command do payload ... end` declaration. Default-attached but replaceable. |
| System command | A command name under the reserved `arbor:` prefix, issued by the runtime/client adapter for internal coordination (e.g., `arbor:request_stream_reload`). Not declarable by store authors. |
| `handle_info/2` | Store callback for arbitrary in-process messages (typically delivered by `Phoenix.PubSub.subscribe/2`). Returns `{:noreply, ctx}` only; produces a patch push if `assigns` change. |
| `assigns` | The private, server-only state map carried on `ctx`. Holds DB results, caches, async state, and any other internal data not part of the public render output. |
| `state do` | The compile-time declaration of a store's public render-output shape. Validated by render-output middleware; codegen target for Elixir typespecs and TypeScript. |
| `child(...)` | A render-time placeholder that the runtime resolves into a child store node by `(parent_path, module, id)` identity. |
| `AsyncResult` | A four-field struct (`loading`, `ok?`, `result`, `failed`) carrying the lifecycle of an async-loaded value; serializable through JSON Patch like any other field. Mirrors `Phoenix.LiveView.AsyncResult`. |
