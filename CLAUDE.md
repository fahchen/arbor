Phoenix 1.8 web application using Shopify Polaris web components for UI.

## Architecture: Three-Layer

### Data Layer (`context/schemas/`)

- Schema modules live in `schemas/` subdirectory of each context
- Contains: `typed_schema`, fields, associations, changesets
- **No `Repo` operations** — changesets are pure data transformations

### Context Layer (`context/`)

- `context.ex` (e.g. `shops.ex`) is a **facade** — only `defdelegate` calls, no logic
- Business logic lives in sibling files organized by responsibility (e.g. `installation.ex`, `profile.ex`, `lookup.ex`)
- `queries/` subdirectory for composable `Ecto.Query` builders — **no DB hits**, only return `Ecto.Query.t()`. External access through a `Queries` facade module (`defdelegate` only, no implementation) — create facades and delegations only when actually needed
- Boundary: `exports: [{Schemas, []}, Queries]` — mass export for schemas (external pattern matching), only the `Queries` facade module for queries (never export specific query modules directly)
- **Cross-context `belongs_to` is allowed** as long as dependencies are unidirectional (no cycles). Use read-only projections only when a direct reference would create a circular dependency. See `docs/architecture/cross-context-dependencies.md`
- `workers/` subdirectory for Oban workers
- **Only** business logic files (not facade, not schemas, not queries) may call `Repo`

### Presentation Layer (`lib/muku_web/`)

- Calls context facades only — never touches `Repo` or schema internals

### Directory Pattern

```
lib/muku/shops/
├── shops.ex              # Facade: defdelegate only
├── installation.ex       # create_shop, mark_uninstalled, reactivate
├── lookup.ex             # get_shop_by_domain, get_shop!
├── profile.ex            # update_profile
├── queries/              # Composable Ecto.Query (no Repo)
│   └── shop_query.ex
├── workers/              # Oban workers
│   └── some_worker.ex
└── schemas/              # TypedEctoSchema + changesets (no Repo)
    └── shop.ex
```

## Rules

- **Never** add functions, modules, or delegations that are not yet used by any caller — introduce them when the first caller needs them
- Run `mix precommit` when done with all changes and fix any pending issues
- `current_scope` errors → move routes to proper `live_session`, pass `current_scope` to `<Layouts.app>`
- **Always** use Polaris web components for all UI — see `docs/agents/polaris-components.md` for full list
- **Never** use custom HTML/Tailwind for elements that have a Polaris equivalent
- **Never** use inline styles (`style="..."`) — always use Tailwind utility classes
- **Polaris layout flow:** `<s-section>` has internal padding but **no external margin**. Sibling sections (in `Layouts.app` body, `<.form>`, fragments, etc.) collapse against each other unless wrapped in an explicit gap container. Use one of the Polaris layout primitives — `<s-stack gap="...">` for vertical/inline flow, `<s-grid gap="...">` for column pairs, `<s-page>` for whole-page section flow. Conventions: `large-100` between sections, `base` for fields inside a section. Never rely on the parent slot to add gap automatically.
- **Slotted children stay direct:** elements with `slot="..."` (e.g. `<s-box slot="aside">`, `<s-button slot="primary-action">`) must be direct children of the host (`<Layouts.app>`, `<s-section>`). Wrapping them inside an `<s-stack>`/`<s-grid>` for spacing breaks slot projection — the slot disappears from its destination. Keep slot nodes as siblings of the layout container, not inside it.
- DOM IDs use BEM style: `block__element--modifier` (modifier = state or id, e.g. `product-form__name--editing`, `order__item--{id}`)
- **DOM IDs only when required for hooks, ARIA, JS targeting, or distinguishing repeated structural elements** — never add ids solely to anchor a test assertion. Tests prefer semantic selectors (`s-section[heading='...']`, `s-button[slot='...']`, descendant chains). The BEM rule above still applies to ids that _are_ required.
- **Avoid LiveComponents** unless specifically needed
- **Always** use `TypedStructor` for structs — never bare `defstruct`
- **Always** use `EctoTypedSchema` (`typed_schema`/`typed_embedded_schema`) — never bare `schema`/`embedded_schema`. Use `typed: [null: false]` for non-nullable field types
- **Always** use `Grephql` for GraphQL requests — never raw HTTP for GraphQL
- **Always** use `Muku.Oban.Worker` with `args_schema` for Oban workers — never plain `Oban.Worker`. Pattern-match `%__MODULE__{}` in `perform/1` for typed args
- **Always** use `Oban` for background jobs — never bare `Task.async` or `spawn`
- **Always** add `@doc` with examples to public functions in context facades and sibling modules. Use `iex>` for doctestable examples, otherwise plain code with `#=>` for return values
- **Always** use `Ecto.Enum` for status fields — never bare `:string`
- **Always** name changesets by purpose (`create_changeset`, `profile_changeset`, `uninstall_changeset`) — never generic `changeset/2`
- **Always** cast external input through a changeset first, then read validated fields from the changeset — never pattern-match on raw params maps
- State-transition fields (status, timestamps like `installed_at`) must only be set through dedicated changesets — never in generic cast fields
- Sibling files in contexts are named by business responsibility (`installation.ex`, `profile.ex`, `lookup.ex`) — never by CRUD (`commands.ex`, `finders.ex`)
- **Lookup naming:** `get_` returns `Schema.t() | nil`, `fetch_` returns `{:ok, Schema.t()} | :error` — never mix the two
- **Always** use `UUIDv7` for all UUID primary/foreign keys and `UUIDv7.t()` in specs — never `Ecto.UUID` or `:binary_id`
- **Always** use `_gid` suffix for Shopify Global ID fields (`ShopifyGid` type) — never `_id` which implies an internal/integer identifier
- **Always** use `params` as the parameter name for changeset/function input — never `attrs`
- **Always** use named bindings in Ecto queries (`[shop: s]`) — never positional (`[s]`)
- **Function ordering:** public functions first, each followed immediately by its private helpers. If a private function serves multiple public functions, place it below all of them. Private functions ordered by call sequence
- **Always** use `async: true` in test modules — design code for concurrency (e.g. per-test GenServer instances, configurable backends). Never use `async: false` as a workaround for shared state
- **Never** modify implementation code solely to make tests pass. If a failure is confined to tests or test infrastructure, fix it in the test layer unless the user explicitly asks for a production behavior change
- **Never** use `Process.sleep` in tests — use built-in wait/retry mechanisms, assertions with timeouts, or `Oban.Testing` helpers
- **Test ordering:** test cases (`describe`/`test`) at the top, helper functions and setup at the bottom. Use `setup` and `@tag` to organize test preparation — avoid inline helper calls
- **Always** use `Repo.transact` for `Ecto.Multi` — never `Repo.transaction` with Multi
- **Transactions**: use `Ecto.Multi` for multi-step transactions; step names can be tuples (e.g. `{:closed_period, period_id}`) to avoid collisions in recursive `Multi.merge/2`. Use `Repo.transact(fn -> with ... end)` only for single-step or very simple branching. Never use `Repo.transaction` with Multi — always `Repo.transact`.
- **Multi query ops**: 用 `Multi.one/3`、`Multi.all/3`、`Multi.exists?/3` 做事务内查询，比 `Multi.run` 包 `repo.one/all` 更声明式。`Multi.run` 保留给需要传入 `repo`（如 `repo.preload`）或做条件/错误分支的步骤。Multi.run callback 参数里的 `repo` 必须用，不能硬编码 `Muku.Repo`。
- **`insert_all` placeholders**: 多行（或单行多引用）共享相同值用 `:placeholders` option，row 字段以 `{:placeholder, key}` 引用。避免 N 次重复 bind 同一字面量。单行且无重复的场景 placeholder 无意义，可跳过。
- **Queries modules**: each module exposes a zero-arity `base/0` returning the starting query with its named binding. Composable builders use `query \\ base()` as the default. Never apply `base()` inside the builder body; never expose `base/1` that accepts a queryable.
- **PubSub events**: topics follow resource-oriented pattern — `<resource>` for collection, `<resource>:<id>` for member. Events are structs (namespace `<Context>.Events.<EventName>`) with required `:id` (UUIDv7) + `:occurred_at` (DateTime) plus event-specific fields. Broadcast payload is the struct — no tuple wrapper. Cross-context propagation uses the relay pattern. Phoenix.PubSub does not support wildcard — every subscriber subscribes to one explicit topic.
- **Always** use `JSON` module (Elixir 1.18+ stdlib) — never `Jason` for encode/decode
- **Always** add parentheses to `@type`/`@typep` definitions — `@type name() ::` not `@type name ::`
- **Always** use `@typep` for types only used within the module — never expose types without external callers
- **Always** add explanatory comments to module attributes, especially magic numbers and non-obvious constants
- **Never** use `Application.put_env` in tests — configure test values in `config/test.exs`
- **Always** use config-driven approach for `Req.Test` plugs — configure in `config/test.exs`, read via `Application.get_env` in production code. Never hardcode `plug: {Req.Test, ...}` in source
- **Always** use `System.fetch_env!` for required environment variables — never `System.get_env` with empty default for credentials
- **Always** use concrete types in specs — never `term()`, `any()`, or bare `atom()`. Error reasons should be specific atom unions, return values should name the actual struct/type
- **Always** use pattern matching in test assertions — never `assert x.field == value`
- **Factories** are organized by context (`AuthFactory`, `ShopFactory`) — never by schema. Test values should come from `config/test.exs` via `Application.get_env`, not hardcoded module attributes
- **Never** seed global/shared data in tests or `test/test_helper.exs` — each test must insert the rows it needs explicitly
- **Never** use `Process.sleep` in tests — use built-in wait/retry mechanisms or assertions with timeouts
- **E2E tests** design from user behaviour (`spec/domains/` features), not implementation. Test what the user sees and does, not DOM structure. No `Process.sleep`
- **E2E + Polaris web components:** PhoenixTest.Playwright's `assert_has`/`fill_in` add `visible=true` which blocks hidden inputs and custom elements. Use `MukuWeb.PolarisHelpers` (backed by `PlaywrightEx.Frame` API) instead — `wait_connected`, `set_input`, `assert_input_value`, `assert_flash`, `assert_sections`. Use Playwright native `click`/`type` for interactions — they support custom element CSS selectors and trigger proper event chains
- **E2E text assertions:** Use `Frame.expect(expression: "to.have.text", expected_text: [%{string: "...", match_substring: true}])` for content-matching with Playwright native polling. No JS `evaluate` with setTimeout, no `Process.sleep`, no manual retry loops — mixing them causes CI timeouts (JS Promise vs GenStatem call timeout mismatch)
- **E2E clearing inputs:** `Frame.fill` on Polaris form components (`s-number-field`, `s-text-field`, etc.) hangs until timeout because it can't find `<input>` in shadow DOM. Use `evaluate("el.value = ''")` for clear, then Playwright `type/3` for input

## Development Workflow

### Dev Loop

1. **Code** — make changes
2. **Simplify** — review and simplify the code for clarity, consistency, and maintainability
3. **Precommit** — run `mix precommit` (compile → deps.unlock --unused → format → oxfmt → oxlint → credo --strict → dialyzer → test)
4. **Fix** — fix all issues until precommit passes clean
5. **Commit** — commit with descriptive message
6. **Push** — push to remote
7. **PR** — create PR using `.github/pull_request_template.md`. Title follows conventional commits (`type(scope): description`). PRs are squash-merged so title/description become the merge commit message
8. **Knowledge** — run `/agent-docs:update-knowledge` to capture new learnings

Always run the full `mix precommit` before considering a task done. Do not skip steps or run individual checks unless debugging a specific failure.

### Feature Build Order

When adding a new feature or context, follow this order:

1. **Schema first** — define `typed_schema`, fields, associations, changesets in `context/schemas/`
2. **Queries** — if shared composable queries are needed, add to `context/queries/`
3. **Business logic** — implement in context sibling files named by business responsibility (e.g. `installation.ex`, `profile.ex`, `lookup.ex`). Never split by CRUD (no `commands.ex`/`finders.ex`)
4. **Facade** — wire up `defdelegate` calls in the context facade (`context.ex`)
5. **Presentation** — build controllers/LiveViews/plugs in `lib/muku_web/`, calling only the facade
6. **Workers** — if background processing is needed, add Oban workers in `context/workers/`

### Where things go

| What               | Where                                    | Repo allowed?                     |
| ------------------ | ---------------------------------------- | --------------------------------- |
| Schema + changeset | `context/schemas/*.ex`                   | No                                |
| Composable queries | `context/queries/*.ex`                   | No (return `Ecto.Query.t()` only) |
| Business logic     | `context/*.ex` (named by responsibility) | Yes                               |
| Context facade     | `context/context.ex`                     | No (`defdelegate` only)           |
| Background jobs    | `context/workers/*.ex`                   | Yes (via context functions)       |
| Web layer          | `lib/muku_web/`                          | No (call context facade)          |

### Naming conventions

- **Facade**: matches context name — `lib/muku/shops/shops.ex` defines `Muku.Shops`
- **Schemas**: singular, namespaced — `lib/muku/shops/schemas/shop.ex` defines `Muku.Shops.Schemas.Shop`
- **Queries**: `{Schema}Query` — `lib/muku/shops/queries/shop_query.ex` defines `Muku.Shops.Queries.ShopQuery`
- **Workers**: descriptive verb — `lib/muku/shops/workers/sync_shop_data.ex` defines `Muku.Shops.Workers.SyncShopData`
- **Tables**: prefixed with context name — `shops`, `auth_offline_tokens`, `billing_plans`, `billing_subscriptions`, `webhooks_deliveries`

## Browser Automation

Use `agent-browser` for web automation. Run `agent-browser --help` for all commands.

Core workflow:

1. `agent-browser open <url>` - Navigate to page
2. `agent-browser snapshot -i` - Get interactive elements with refs (@e1, @e2)
3. `agent-browser click @e1` / `fill @e2 "text"` - Interact using refs
4. Re-snapshot after page changes

## Orchestrated Work (worktree handoffs)

When a worktree receives a handoff (`.agents/.handoff/*.md`):

1. **Use planning-with-files** — invoke `planning-with-files:plan` before any code. Track phases, decisions, errors in `task_plan.md`/`findings.md`/`progress.md`.
2. **Delegate implementation to sub-agents** — do NOT write code in the main agent turn. Launch sub-agents (via `Agent` tool) to do the actual implementation work. Main agent coordinates and reviews.
3. **Codex review before PR** — after implementation is complete locally (precommit green), invoke `codex:rescue` skill to review. Discuss and iterate with Codex until it approves the change. Only then create the PR.
4. **Then** push + `gh pr create` with the PR template.

## Project Knowledge

Before coding, load project knowledge into context:

1. **Read fully:** `docs/agents/knowledge.md` and `docs/agents/patterns.md`
2. **Scan titles only:** `docs/agents/improvements.md` — read full entry only when relevant
3. **Scan frontmatter only:** `docs/agents/postmortems/*.md` — read full postmortem only when relevant

Use `/agent-docs:update-knowledge` to capture new learnings after a session.
