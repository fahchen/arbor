# Copilot code review playbook

This file guides GitHub Copilot's review of pull requests in this repo. Arbor has a real BDD spec and explicit decision records. **Spec is authoritative**: code that contradicts the spec is a bug, regardless of test pass/fail status. Cite the exact spec line when flagging a violation.

## Where the spec lives

- `spec/domains/<domain>/features/*.feature` — Gherkin scenarios. Domains: `runtime`, `replication`, `streams`, `async`.
- `spec/decisions/BDR-NNNN-<slug>.md` — accepted Behavioral Decision Records. Each one ties back to a feature rule. The current set covers:
  - `BDR-0001` outcome via transport reply
  - `BDR-0002` handler return shape (LV-aligned)
  - `BDR-0003` handler crash = let-it-crash
  - `BDR-0004` cross-cutting concerns via `attach_hook` (sole extension primitive)
  - `BDR-0005` no built-in PubSub layer
  - `BDR-0006` effect mechanism = socket pipe
  - `BDR-0007` pipeline declaration order
  - `BDR-0008` authorization = graceful halt, not wire error
  - `BDR-0009` outcome ordering (reply → patch → effects)
  - `BDR-0010` attr/assigns unified namespace
  - `BDR-0011` conditional child = fresh mount on reappearance
  - `BDR-0012` no per-child unmount callback
  - `BDR-0013` memoization via `socket.assigns.__changed__` ref equality
  - `BDR-0014` pure structural minimal diff (no threshold, no fallback)
  - `BDR-0015` no resync command — reconnect is the recovery path
  - `BDR-0018` stream-only render cycles still emit a patch envelope
  - `BDR-0019` `start_async` same-name overwrite + lazy-discard
  - `BDR-0020` `handle_async/3` exceptions caught (diverges from let-it-crash)
  - `BDR-0022` reload vs `stream_async(reset:)` — silent vs loading-flash
- `spec/glossary.md` — domain terms.
- `spec/backlog.md` — out-of-scope or planned work (e.g. persistence is **not** an Arbor primitive).

When the diff touches a feature file's domain, **read the relevant `.feature` and any matching BDR before reviewing**. If a code change adds behavior, ask: is there a scenario for it? If a code change weakens behavior, is there a scenario that breaks?

## Spec-violation review checklist

Flag any of the following:

1. **Renamed/removed scenario behavior in code without spec update.** If a feature file says "When the client sends a command targeting path X, then the runtime dispatches to Y" and the diff changes that path or dispatch, the spec must change in the same PR (or the change is out of scope).
2. **New behavior introduced without a scenario.** Major user-visible behavior (new envelope shape, new hook stage, new socket helper, new reflection key) needs at least one scenario in the matching `.feature` file before merge.
3. **Decision-record contradiction.** If the diff implements something a `BDR-NNNN.md` already rules out (e.g. introducing a `middleware` macro against `BDR-0004`, adding a `move`/`copy`/`test` JSON Patch op against `BDR-0014`, building an Arbor PubSub wrapper against `BDR-0005`), block and link the BDR.
4. **Glossary drift.** If naming conflicts with `spec/glossary.md`, flag.

## Cross-cutting concerns (always check)

### typed_structor / DSL invariants

- All structs use `TypedStructor` — never bare `defstruct`. The exception is the special-purpose `Arbor.Plugin.Definer` which intentionally implements typed_structor's `define/1` callback.
- `Arbor.DSL.State.field/3` wraps opts in `Macro.escape/1` so closures (`item_key: &…`) survive into reflection. **Do not strip this** — stream metadata depends on it.
- `Arbor.Plugin.StateField` collects field metadata per-block via `after_definition/2`, normalising via `Arbor.Plugin.Normalize.fields/1`. Don't reintroduce a parallel normaliser.
- `Module.__arbor__/1` is the stable reflection surface. Keys: `:fields | :commands | :streams | :attrs | {:type, name}`. Adding a new key needs a deliberate decision; renaming an existing key is a breaking change.
- The `command :name do payload :foo, T end` DSL deliberately does **not** use a typed_structor block, because per-command sub-modules + credo's `UnsafeToAtom` rule are irreconcilable. Any PR that re-introduces typed_structor for commands must also explain how it avoids both `@type t/0` collisions across multiple blocks and dynamic-atom-creation warnings.

### Socket and assigns

- `%Arbor.Socket{}` mirrors `Phoenix.Socket`'s field shape: `assigns`, `id`, `parent_path`, `module`, `endpoint`, `topic`, `transport_pid`, `private`. Don't add public fields without a spec update.
- `socket.assigns.__changed__` is the LV-style change-tracking map (`%{key => true}`). `assign/3` records via `===` (no-op writes are skipped). The runtime resets `__changed__` to `%{}` after each render cycle (BDR-0013).
- `socket.private[:hooks]` is reserved for `Arbor.Hook`. Direct struct writes to `private` are still possible in Elixir; review prefers writes through `Arbor.Socket.put_private/3` / `get_private/3` for discipline.

### Hook pipeline

- Stages: `:before_command | :after_command | :handle_async | :handle_info | :after_to_state` (BDR-0004). New stages need a BDR.
- Hook return shapes: `{:cont, socket}` always allowed; `{:halt, socket}` always allowed; `{:halt, reply, socket}` only when the caller asserts `halt_payloads_allowed?: true`. Other shapes raise.
- Re-attaching the same `id` on the same `stage` raises `ArgumentError`. `detach_hook/3` is a silent no-op when absent. Don't relax either.

### Identity and reconciliation

- `(parent_path, module, id)` is the runtime identity of a child node (BDR-0011). `id` must be a binary string — non-strings and missing ids are rejected at the resolver. Numeric ids must be `to_string/1`'d at the call site.
- A child whose identity disappears is silently dropped — no per-child `terminate` callback (BDR-0012). Reappearance is a fresh mount with no preserved assigns.

### Diff engine and replication

- The diff engine emits the **structural minimal** RFC 6902 diff with no threshold and no subtree-replace fallback (BDR-0014). Reorders without a `move` op produce per-index `replace` ops; that's intentional.
- Only `add | remove | replace` ops are emitted. `move`, `copy`, and `test` are out of scope.
- Path values are RFC 6901 JSON Pointer strings. Authors do not assemble paths manually — go through the JSON Pointer library.
- A render cycle that yields no JSON Patch ops AND no stream ops emits no envelope. A cycle that yields stream ops only **does** emit an envelope (BDR-0018).
- Initial state delivery is the first patch envelope (`base_version: 0, version: 1, ops: [{replace, "", root}]`). No separate "snapshot" envelope.

### Streams and async

- `stream :name, T, opts` is a state-block field declaration. Top-level `stream` macro outside `state do` is wrong.
- `__arbor__(:streams)` lists only top-level `stream/3` declarations. Composite types like `AsyncResult.of(stream(T))` are intentionally **not** registered as stream slots in M1; `stream_async` (M5) owns that pipeline.
- Stream API is LV-parity: `stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_item_key/3` (note: `_by_item_key`, not `_by_dom_id` — Arbor has no DOM ids).
- Async API is LV-parity: `assign_async/3,4`, `start_async/3,4`, `cancel_async/2,3`, `handle_async/3`, plus the `:timeout` extension. `stream_async/4` is also LV-parity (Phoenix.LiveView 1.1+).
- `start_async` same-name calls silently overwrite the tracked ref; old tasks continue but their results are lazy-discarded with `[:arbor, :async, :lazy_discard]` telemetry (BDR-0019). Don't introduce auto-cancel.
- `handle_async/3` exceptions are **caught** by the runtime (BDR-0020) — diverges from the let-it-crash policy that applies to command/render handlers (BDR-0003). Don't make `handle_async/3` crash the runtime.

### Authorization

- Authorization is a `:before_command` hook returning `{:halt, %{ok: false, reason: …}, socket}`. Channel reply status stays `:ok`; the payload carries the explicit denial flag (BDR-0008). There is no wire-level error category for unauthorized.
- Malformed/impossible commands (unknown path, undeclared command, schema-violating payload) raise inside the runtime; the page process exits per let-it-crash (BDR-0003). Don't add a graceful-error wire path for those.

### Naming conventions worth flagging on review

- `params` (not `attrs`) for changeset/function input names.
- Concrete error specs (`{:error, :not_found | :forbidden}`), not `term()` / `any()` / bare `atom()`.
- `get_*` returns `T | nil`; `fetch_*` returns `{:ok, T} | :error`. Don't mix.
- `@type` and `@typep` always include parentheses: `@type t() ::`, not `@type t ::`.
- `@typep` for module-internal types; `@type` only when there's an external caller.
- Doctest examples reference public APIs only — never name a private helper.

### Test conventions

- `async: true` everywhere. `async: false` is a smell; flag and ask for the underlying shared-state fix.
- No `Process.sleep` in tests.
- Pattern matching in test assertions (`assert %{key: value} = result`), not field-by-field equality.
- Test cases (`describe`/`test`) at the top of the file; helper functions and `setup` blocks at the bottom.
- Fixtures and test-support modules live under `test/arbor/...` mirroring `lib/arbor/...`. Don't drop fixtures into `test/test_helper.exs`.
- Compile-time DSL tests use `Code.compile_string/1` + `assert_raise` to verify compile errors; don't try to assert at runtime what is actually a compile error.

## Test coverage review (TDD)

This repo is developed test-first. Tests are part of the contract, not an afterthought. Review test files with the same rigor as production code.

### Happy path + edge cases

For every new public function or behavior, verify:

- **Happy path** has at least one test asserting the documented success case.
- **Edge cases** are explicitly tested: nil inputs, empty lists/maps, missing optional fields, boundary values (0 / 1 / many), wrong shape (string vs list vs nil) when public APIs accept varied input.
- **Error paths** are tested: each `{:error, ...}` branch and each raise. Don't leave error reasons untested — flag specs that name an error tuple no test covers.
- **State transitions** (mount → update → render → terminate, hook attach/detach, async lifecycle states) have a test per legal transition AND at least one negative test for an illegal transition.

If a diff adds behavior without covering at least the happy path + one edge case, request the missing tests.

### Unit test redundancy

Unit tests should not overlap. Flag:

- **Two tests asserting the same thing** with cosmetic differences (different variable names, different fixture, same outcome). Pick one.
- **A test that re-asserts what an upstream test already covers**. Each test should add unique signal.
- **Test names that lie** (`test "registers a stream slot"` that actually only checks the field is in `:fields` — name and assertion must match).
- **Dead test setup** (factories built but never used in the assertions, fixtures with extra fields the test doesn't read). Trim.
- **Snapshot-style assertions that re-test the same field across multiple tests** when one parameterized test or one structural assertion would do.

The bar: removing any test should observably reduce coverage. If two tests would fail or pass together for the same reason, one of them is redundant.

### Spec-traced coverage

Tests for `lib/arbor/*` should be traceable to a Gherkin scenario in `spec/domains/<domain>/features/*.feature` whenever the behavior is user-visible. When reviewing a new test file:

- **Verify a matching scenario exists** in the relevant `.feature` file. Quote the `Scenario:` title in the PR description or in a test comment so the link is explicit.
- **Test names should echo scenario names** for spec-traced behavior.
- **No test for behavior that has no scenario.** If a diff adds a test for behavior the spec doesn't describe, flag and request a scenario added in the same PR (or an explicit out-of-spec justification).

A spec scenario without a matching test is a coverage gap — flag during review, even if the diff doesn't introduce it (the scenario already existed).

## Severity hints

- **Block** (don't approve): spec violation without spec update, BDR contradiction, hook-stage / reflection-key rename without spec update, `move`/`copy`/`test` JSON Patch op introduction, `middleware` macro re-introduction, force-push or amend-and-push on a published commit, security/let-it-crash bypass in the wrong layer, new behavior with no happy-path test.
- **Comment** (request fix before merge): missing edge-case tests, redundant/overlapping unit tests, comment/doc inaccuracy, naming drift from glossary, `Macro.escape(opts)` removal, `socket.private` writes that bypass `put_private/3`, telemetry-event name churn, test name doesn't echo a scenario title.
- **Suggestion**: typo, minor refactor, naming nits.

## What not to flag

- Style preferences when the existing codebase has chosen a different style consistently. Defer to surrounding code.
- Hypothetical future scenarios that the spec doesn't cover.
- Conventions covered by `AGENTS.md` for code generation but not visible in the diff.
