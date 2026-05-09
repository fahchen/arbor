# AGENTS.md

Conventions for AI agents (and humans) working in this repository.

## Project

**Arbor** is a server-authoritative, page-scoped runtime library for Elixir/Phoenix. One BEAM process per connected page owns a hierarchical tree of stores, routes commands to addressed nodes, computes a structured render output, and pushes RFC 6902 JSON Patch updates plus stream-op envelopes to the client.

This repository is the Arbor runtime library itself. Application examples live under `examples/` (M6).

## Stack

- Elixir 1.19 (managed by `mise`; see `mise.toml`)
- `{:typed_structor, "~> 0.6.1"}` — struct definitions and plugin-based metadata
- `{:jsonpatch, "~> 2.2"}` (corka149/jsonpatch) — RFC 6902 diff/apply + JSON Pointer
- Phoenix Channel (transport, M4)
- Phoenix.PubSub (consumed by application code; not wrapped by Arbor)
- `Task.Supervisor` (async, M5)

## Repository layout

```
lib/arbor/
  store.ex                # use Arbor.Store
  state.ex                # use Arbor.State
  socket.ex               # %Arbor.Socket{} struct + assigns helpers
  page_runtime.ex         # GenServer (one per connected page)
  hook.ex                 # attach_hook/4, detach_hook/3, run_hooks/4
  store_registry.ex       # mounted-node lookup table
  async_result.ex         # AsyncResult.of/1 type marker (runtime struct in M5)
  dsl/                    # state, command, attr macros
  plugin/                 # typed_structor plugins (StateField, Reflection, TypeSpec, …)
  test_support/           # fixtures only used in tests

test/arbor/               # tests mirror lib/arbor/ structure

spec/                     # AUTHORITATIVE behaviour spec (see "Source of truth")
  glossary.md
  backlog.md
  decisions/              # BDR-NNNN architectural decision records
  domains/<area>/features/*.feature   # Gherkin specs

docs/
  PRD.md                  # narrative product description
  task-priority.html      # internal planning visualisation

task_plan.md              # phase-by-phase task list (root)
findings.md               # research notes (root)
progress.md               # session log (root)
```

## Source of truth

Spec wins when PRD and spec disagree. Order of authority:

1. `spec/domains/**/*.feature` — Gherkin scenarios that the runtime must satisfy
2. `spec/decisions/BDR-*.md` — architectural decisions (tagged in feature scenarios)
3. `spec/glossary.md` — domain terminology
4. `docs/PRD.md` — narrative; informational only when it conflicts with spec

If a spec or BDR feels wrong, propose a change to the spec — do not silently diverge in code. Flag the discrepancy in your PR description and let the maintainer decide whether to amend the spec or revise the implementation.

## Commands

- `mix deps.get` — fetch deps
- `mix compile` — compile the project
- `mix test` — run the test suite
- `mix format` — format the project
- `mix credo --strict` — strict lint pass
- `mix dialyzer` — type-check (PLT bootstrapping is slow on first run)
- `mix precommit` — runs the full gate: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `credo --strict`, `dialyzer`, `test`. **Every PR must pass `mix precommit`.**

## Code conventions

- Public functions need `@spec`. Modules need `@moduledoc` (one line OK; `@moduledoc false` for internal modules).
- New files go under `lib/arbor/` and `test/arbor/`, mirroring the existing layout. Don't touch `test/test_helper.exs` from feature branches without a clear reason — it's a common merge-conflict surface.
- Field-, command-, attr-, and stream-shaped declarations live inside the existing typed_structor plugin pipeline. New compile-time metadata should generally be reachable via `Module.__arbor__/1` reflection.
- Keep `socket.private` writes behind `Arbor.Socket.put_private/3` / `get_private/3` rather than direct struct updates.

## Reflection contract — `Module.__arbor__/1`

Stores and `Arbor.State` modules expose a single reflection entry point. Keys are stable across phases:

| Call | Returns |
|------|---------|
| `__arbor__(:fields)` | `[%{name, type, opts}]` for every `state do` field |
| `__arbor__(:commands)` | `[%{name, payload_fields, opts}]` for every `command :name [do payload …end]` |
| `__arbor__(:streams)` | `[%{name, item_type, item_key, limit, opts}]` for top-level `stream :name, T, opts` declarations |
| `__arbor__(:attrs)` | `[%{name, type, required, default}]` for every `attr :name, T, opts` |
| `__arbor__({:type, name})` | quoted AST for one field's declared type |

`item_key` and `:item_key` opts retain quoted AST form so closures (e.g. `&"msg-#{&1.id}"`) survive reflection. `:limit` is normalised to a literal integer.

## Cross-track invariants

These contracts are load-bearing across phases. Keep them stable; if you must change them, do it in a deliberate PR, not a drive-by commit.

- `%Arbor.Socket{}` field shape: `assigns`, `id`, `parent_path`, `module`, `endpoint`, `topic`, `transport_pid`, `private`. Mirrors `Phoenix.Socket`.
- `socket.assigns.__changed__` records mutations as `%{key => true}`. `===` comparison short-circuits no-op writes (BDR-0013). The runtime resets it after each render cycle.
- `socket.private[:hooks]` is reserved for `Arbor.Hook`'s per-node hook table.
- Hook stages: `:before_command | :after_command | :handle_async | :handle_info | :after_to_state` (BDR-0004).
- Hook return shapes: `{:cont, socket} | {:halt, socket} | {:halt, reply, socket}` (last one only when the caller passes `halt_payloads_allowed?: true`).
- `{parent_path, module, id}` is the runtime identity of a child node. `id` must be a binary string (BDR-0011).

## Git conventions

- **Never force-push.** That includes `git push --force-with-lease`. To address review feedback, stack a new commit on the branch tip — do not amend and force.
- **Never `git commit --amend` on a published commit.** Add a follow-up commit instead.
- Commits should be focused; mix small unrelated changes into separate commits when reasonable.
- Use the conventional Conventional-Commits-ish prefix style already visible in history (`feat(m1):`, `chore:`, `docs:`, `fix:`).
- Co-author trailers (`Co-Authored-By: …`) are welcome but not required.
- PRs target `main`. Repository is configured for **squash merges only** (no merge commits, no rebase merges).

## Spec amendments

If implementation work surfaces a behaviour that contradicts the existing spec:

1. Implement what the maintainer asked for.
2. **Flag the discrepancy** in the PR description with the file and line number of the affected `.feature` rule, BDR, or glossary entry.
3. Do **not** edit `spec/` files yourself unless the maintainer explicitly asks. The spec is jointly owned and amendments are typically discussed and tracked in a separate PR.

## Working with multiple worktrees

This project frequently uses paseo-managed worktrees for parallel feature development. When merging branches:

- After a sibling branch lands on `main`, merge `main` into your branch (do not rebase) so review history is preserved.
- Resolve conflicts deliberately. Cross-track integration patches (e.g. wiring a new module into existing reflection) belong in their own commit on top of the merge commit, not folded into the merge resolution itself.
- `mix.lock` conflicts are normally fixed by re-running `mix deps.get` after the merge.

## Caveats and known land mines

- `typed_structor` evaluates field opts eagerly. `Arbor.DSL.State.field/3` deliberately wraps opts in `Macro.escape/1` so closures (`item_key: &…`) survive into reflection. Do not strip this without rewriting the stream pipeline.
- `Credo.Check.Warning.UnsafeToAtom` flags every dynamic-atom path (`:"…"` interpolation, `Module.concat/1,2`, `String.to_atom/1`). Avoid creating dynamic atoms in macro-expansion paths if there's any way around it.
- `Arbor.AsyncResult.of/1` is currently a type marker only; the runtime struct is M5 work.
- Stream slot registration in `__arbor__(:streams)` only covers top-level `stream :name, T` declarations. Composite types like `AsyncResult.of(stream(T))` are intentionally not registered as stream slots in M1; M5's `stream_async` pipeline owns that.
