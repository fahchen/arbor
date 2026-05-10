# AGENTS.md

Server-authoritative, page-scoped runtime library for Elixir/Phoenix. One BEAM process per connected page owns a tree of stores; pushes RFC 6902 JSON Patch updates to the client.

## Stack

- Elixir 1.19 (managed via `mise`)
- `{:typed_structor, "~> 0.6.1"}` — struct definitions and plugin-based metadata
- `{:jsonpatch, "~> 2.2"}` (corka149/jsonpatch) — RFC 6902 diff/apply
- `Phoenix.Channel` (transport, M4); `Phoenix.PubSub` is used by application code, not wrapped (BDR-0005)

## Source of truth

`spec/` wins when PRD and spec disagree. Order of authority:

1. `spec/domains/**/*.feature`
2. `spec/decisions/BDR-*.md`
3. `spec/glossary.md`
4. `docs/PRD.md` (informational)

If the spec feels wrong, flag the discrepancy in the PR — never silently edit `spec/` files.

## Rules

- **Never** add functions, modules, or delegations that are not yet used by any caller — introduce them when the first caller needs them
- Run `mix precommit` when done with all changes and fix any pending issues
- **Always** use `TypedStructor` for structs — never bare `defstruct`
- **Always** add `@doc` with examples to public functions. Use `iex>` for doctestable examples, otherwise plain code with `#=>` for return values
- **Always** use concrete types in specs — never `term()`, `any()`, or bare `atom()`. Error reasons should be specific atom unions, return values should name the actual struct/type
- **Always** add parentheses to `@type`/`@typep` definitions — `@type name() ::` not `@type name ::`
- **Always** use `@typep` for types only used within the module — never expose types without external callers
- **Always** add explanatory comments to module attributes, especially magic numbers and non-obvious constants
- **Always** use `params` as the parameter name for changeset/function input — never `attrs`
- **Always** use `JSON` module (Elixir 1.18+ stdlib) — never `Jason` for encode/decode
- **Always** use `System.fetch_env!` for required environment variables — never `System.get_env` with empty default for credentials
- **Lookup naming:** `get_` returns `Schema.t() | nil`, `fetch_` returns `{:ok, Schema.t()} | :error` — never mix the two
- **Function ordering:** public functions first, each followed immediately by its private helpers. If a private function serves multiple public functions, place it below all of them. Private functions ordered by call sequence
- Sibling files in a directory are named by responsibility — never by CRUD (`commands.ex`/`finders.ex`)
- **Always** use `async: true` in test modules — design code for concurrency. Never use `async: false` as a workaround for shared state
- **Never** modify implementation code solely to make tests pass. If a failure is confined to tests or test infrastructure, fix it in the test layer unless the user explicitly asks for a production behavior change
- **Never** use `Process.sleep` in tests — use built-in wait/retry mechanisms or assertions with timeouts
- **Test ordering:** test cases (`describe`/`test`) at the top, helper functions and setup at the bottom. Use `setup` and `@tag` to organize test preparation — avoid inline helper calls
- **Always** use pattern matching in test assertions — never `assert x.field == value`
- **Never** seed global/shared data in tests or `test/test_helper.exs` — each test must insert the rows it needs explicitly
- **Never** use `Application.put_env` in tests — configure test values in `config/test.exs`
- **Never** force-push (including `--force-with-lease`). To address review feedback, stack a new commit on the branch tip — do not amend and force
- **Never** `git commit --amend` on a published commit — add a follow-up commit instead

## Arbor-specific contracts

- `%Arbor.Socket{}` field shape: `assigns`, `id`, `parent_path`, `module`, `endpoint`, `topic`, `transport_pid`, `private`. Mirrors `Phoenix.Socket`
- `socket.assigns.__changed__` records mutations as `%{key => true}`; `===` short-circuits no-op writes (BDR-0013)
- `socket.private[:hooks]` is reserved for `Arbor.Lifecycle` — write via `Arbor.Socket.put_private/3`
- Hook stages: `:before_command | :after_command | :handle_async | :handle_info | :after_to_state | :after_serialize` (BDR-0004)
- Hook fun arity is stage-dependent: `:before_command`/`:after_command`/`:handle_async` are arity 3, `:handle_info`/`:after_to_state`/`:after_serialize` are arity 2
- `:after_to_state` runs on the resolved Elixir term (atom keys, structs, atom values); `:after_serialize` runs on the wire term (string keys, plain maps, atoms-as-strings) produced by `Arbor.Wire.to_wire/1`
- Hook return: `{:cont, socket} | {:halt, socket} | {:halt, reply, socket}`
- Child identity is `{parent_path, module, id}`; `id` must be a binary (BDR-0011)
- `Module.__arbor__/1` reflection keys: `:fields`, `:commands`, `:streams`, `:attrs`, `{:type, name}`. Singular variants `__arbor__/2` accept `:field | :command | :stream | :attr` plus a name and return `{:ok, def} | :error`
- Stream runtime helpers (compile-time generated alongside `__arbor__/1`): `Module.__arbor_stream_config__(name) :: %{item_key: fun, limit: integer | nil}` and `Module.__arbor_stream_item_key__(name, item) :: binary` — used by `Arbor.Stream` so callers never `Code.eval_quoted/3` the AST stored on `:streams`
- typed_structor evaluates field opts eagerly — `Arbor.DSL.State.field/3` wraps opts in `Macro.escape/1` so `item_key: &…` captures survive into reflection. Don't strip this
- Module-kind contract:

  | use directive    | role                   | DSL block | reflection callback           |
  | ---------------- | ---------------------- | --------- | ----------------------------- |
  | use Arbor.Store  | store + lifecycle      | state do  | __arbor_validate_state__/1    |
  | use Arbor.State  | render output type     | state do  | __arbor_validate_state__/1    |
  | use Arbor.Input  | input data type        | input do  | __arbor_validate_input__/1    |
- Stream API (LV-aligned, frozen for M4+): `Arbor.Stream.stream/3,4`, `stream_configure/3`, `stream_insert/3,4`, `stream_delete/3`, `stream_delete_by_item_key/3`. Note Arbor uses `_by_item_key` where LV uses `_by_dom_id`. The runtime queues raw delta ops on a per-stream `Arbor.LiveStream` struct — it does **not** maintain an ordered `item_keys` list, decide upsert-vs-insert, or trim for `:limit` (the client owns materialization). `stream_configure/3` is a lifetime gate: raises if called after the stream is initialized
- Reserved socket-assigns shape: `socket.assigns.__streams__ = %{__ref__: int, __changed__: MapSet, __configured__: %{name => opts}, <name> => %Arbor.LiveStream{}}`. The drained-ops accumulator lives at `socket.private[:__arbor_drained_stream_ops__]` (populated by `Arbor.Hooks.PruneStreams`, consumed by `Arbor.Page.Server`). Do not read or write directly
- `Arbor.LiveStream` (typed_structor) is the per-stream pending struct: `name`, `item_key_fun`, `ref`, `inserts`, `deletes`, `reset?`. `Arbor.LiveStream.prune/1` clears `inserts`/`deletes`/`reset?` and is called once per cycle by the prune hook
- Default lifecycle hook `Arbor.Hooks.PruneStreams` runs on `:after_serialize`, drains pending ops from each `LiveStream` marked changed into the per-socket accumulator, prunes the struct, and clears `__changed__`. The page server collects from the accumulator after the resolver returns
- Stream wire-op shape (carried in `PatchEnvelope.stream_ops`): `%{op: "insert", stream: name_str, ref: ref_str, item_key, at, item, limit}`, `%{op: "delete", stream: name_str, ref: ref_str, item_key}`, `%{op: "reset", stream: name_str, ref: ref_str}`. `stream_configure/3` is server-side only — no configure op appears on the wire (the `item_key` capture is not transferable; per-insert `limit` carries what the client needs)
- `Arbor.Page.PatchEnvelope.t` shape: `type: "patch"`, `base_version`, `version`, `ops`, `stream_ops`. `version` is a monotonic per-page counter starting at 1 (initial bootstrap envelope) and resetting on reconnect (fresh page server). `ops` only carries `add`/`remove`/`replace` (BDR-0014); `move`/`copy`/`test` are filtered. Stream-typed paths never appear in `ops` — content flows entirely via `stream_ops`. Idle render cycles emit no envelope (BDR-0018)
- Telemetry events emitted by the runtime: `[:arbor, :command, :start | :stop | :exception]`, `[:arbor, :render, :stop]`, `[:arbor, :resolve, :stop]`, `[:arbor, :validate, :stop | :exception]`, `[:arbor, :diff, :stop]`, `[:arbor, :patch, :stop]`, `[:arbor, :stream, :flush]`

## Workflow

1. **Code** — make changes
2. **Precommit** — run `mix precommit` (compile → deps.unlock --unused → format → credo --strict → dialyzer → test)
3. **Fix** — fix all issues until precommit passes clean
4. **Commit** — descriptive message, conventional-commits prefix (`feat(m1):`, `fix:`, `docs:`)
5. **Push** — `git push origin <branch>` (no flags)
6. **PR** — `gh pr create --base main`. Title is the squash-merge commit message; PRs target `main`; repo is squash-merge only

## Worktree handoffs (paseo)

When a worktree receives a handoff:

1. **Plan first** — invoke `planning-with-files:plan`. Track phases/decisions/errors in `task_plan.md`/`findings.md`/`progress.md`
2. **Delegate implementation to sub-agents** — coordinate from the main agent; let sub-agents do the writing
3. **Merge `main` into your branch** (do not rebase) when a sibling lands on `main`. Resolve `mix.lock` conflicts by re-running `mix deps.get`
4. **Then** push + open PR
