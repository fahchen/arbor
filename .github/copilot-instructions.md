# Copilot code review playbook

Conventions, contracts, and Elixir style live in [`AGENTS.md`](../AGENTS.md). **Do not restate them here.** This file describes only what the reviewer should additionally look for when reading a diff.

The repo has a real BDD spec under `spec/`. **Spec is authoritative**: code that contradicts the spec is a bug regardless of test pass/fail. Cite the exact `Scenario:` line or `BDR-NNNN` slug when flagging a violation.

## Where the spec lives

- `spec/domains/<domain>/features/*.feature` — Gherkin scenarios. Domains: `runtime`, `replication`, `streams`, `async`.
- `spec/decisions/BDR-NNNN-*.md` — accepted Behavioral Decision Records. Filenames are self-describing; read the BDR a diff touches, don't pattern-match on the number.
- `spec/glossary.md` — domain terms.
- `spec/backlog.md` — out-of-scope or deferred work.

When a diff touches a domain, **read the relevant `.feature` and any matching BDR before reviewing**. Don't rely on memory.

## Spec-violation checklist

1. **Behavior changed without spec changing.** A feature scenario fixes the wire shape, the hook order, the diff op set, the identity tuple, etc. If the diff alters one of those and `spec/` doesn't change in the same PR, block.
2. **New behavior with no scenario.** New socket helper, new envelope field, new hook stage, new reflection key, new wire op kind: needs a scenario in the matching `.feature` file before merge.
3. **BDR contradiction.** If the diff implements something a BDR rules out, block and link the BDR.
4. **Glossary drift.** If naming conflicts with `spec/glossary.md`, flag.

## What to look for in this codebase

The high-leverage review questions, beyond the conventions in `AGENTS.md`:

- **Reflection surface stability.** `Module.__arbor__/1` keys are a public contract. Renaming a key is breaking; adding one needs a deliberate decision (preferably surfaced in the PR description, not buried in a plugin file).
- **`Macro.escape(opts)` invariants.** Stream metadata (`item_key: &…`) and any other AST that survives into reflection must stay quoted. Diffs that drop `Macro.escape/1` from a DSL macro need a spelled-out reason.
- **`socket.private` discipline.** Writes to `socket.private` should go through `Arbor.Socket.put_private/3` rather than direct struct updates, even though both compile.
- **Hook return shapes.** `{:cont, socket} | {:halt, socket} | {:halt, reply, socket}`. The third form is only legal when the caller passed `halt_payloads_allowed?: true`. Diffs that broaden this must change `Arbor.Hook.run_hooks/4`'s contract and the matching scenarios.
- **Hook arity is stage-dependent.** `:before_command`/`:after_command`/`:handle_async` hooks take three arguments, `:handle_info`/`:after_to_state` take two. Diffs that flatten hook arity back to one generic shape should be questioned.
- **Diff engine purity.** Only `add | remove | replace` JSON Patch ops. No `move`, `copy`, `test`. No subtree-replace fallback. No size threshold.
- **Let-it-crash vs caught.** Command and render handlers crash the page runtime; `handle_async/3` exceptions are caught. Diffs that flip either side need a BDR-level discussion.
- **typed_structor `command` DSL boundary.** `command :name do payload …end` deliberately does **not** use a typed_structor block (per-command sub-modules + credo's `UnsafeToAtom` rule are irreconcilable). Re-introducing typed_structor for commands needs a concrete plan for both `@type t/0` collisions and dynamic-atom warnings.
- **LV-parity surfaces.** `stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_item_key/3`, `assign_async/3,4`, `start_async/3,4`, `cancel_async/2,3`, `handle_async/3`, `stream_async/4` (Phoenix.LiveView 1.1+ also has it). Diffs that change semantics from LV without a corresponding scenario should be questioned.

## Test review

Same standards as production code:

- **Happy path + edge case + error path.** Every public function or new behavior needs at least the happy path. Each `{:error, …}` branch and each raise must be covered.
- **Spec-traced.** Tests for user-visible behavior should map to a Gherkin scenario. Test names should echo `Scenario:` titles when applicable. Behavior with no scenario in the spec is itself a flag (either add the scenario or justify the gap).
- **Compile-time DSL tests.** Use `Code.compile_string/1` + `assert_raise` for compile errors; don't try to assert at runtime what is a compile error.
- **No redundancy.** Two tests that fail or pass together for the same reason → one is dead weight. Test names that lie about what they assert are worse than no test name.

## Severity hints

- **Block** (don't approve): spec violation without spec update; BDR contradiction; reflection-key rename; new JSON Patch op kind; let-it-crash bypass on command/render handlers; force-push or `--amend` on a published commit; new behavior without happy-path test.
- **Comment** (request fix before merge): missing edge-case or error-path tests; redundant or mis-named tests; `Macro.escape(opts)` removed without reason; `socket.private` writes that bypass `put_private/3`; telemetry-event name churn.
- **Suggestion**: typo, minor refactor, naming nit.

## What not to flag

- Anything already covered by `AGENTS.md`. Trust that the contributor read it.
- Style preferences when the existing codebase has chosen a different style consistently. Defer to surrounding code.
- Hypothetical future scenarios the spec doesn't cover.
