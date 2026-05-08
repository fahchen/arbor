@async @lifecycle
Feature: Async Task Lifecycle
  As a store author
  I want to launch background tasks whose results integrate with ctx.assigns and the wire shape via Arbor.AsyncResult
  So that long-running work runs off the runtime mailbox and clients see explicit loading, ok, and failed states

  Background:
    Given a connected client
    And a page runtime mounted on the client's transport session

  Rule: Arbor.AsyncResult is a four-field struct mirroring Phoenix.LiveView.AsyncResult

    Scenario: Loading default
      When code calls Arbor.AsyncResult.loading()
      Then the struct has loading: true, ok?: false, result: nil, failed: nil

    Scenario: Ok preserves prior loading semantics
      When code calls Arbor.AsyncResult.ok(prior, value)
      Then the struct has ok?: true, result: value, loading: nil, failed: nil

    Scenario: Failed preserves prior loading semantics
      When code calls Arbor.AsyncResult.failed(prior, {:error, reason})
      Then the struct has failed: {:error, reason}, loading: nil

  Rule: assign_async writes loading synchronously and resolves to ok or failed when the task completes

    Scenario: Single key happy path
      When the application calls assign_async(ctx, :profile, fn -> {:ok, %{profile: data}} end)
      Then ctx.assigns.profile is set to Arbor.AsyncResult.loading([:profile]) immediately
      And on task completion ctx.assigns.profile becomes Arbor.AsyncResult.ok(prior, data)

    Scenario: Multi-key atomic write
      When the application calls assign_async(ctx, [:user, :org], fn -> {:ok, %{user: u, org: o}} end)
      Then both keys are set to Arbor.AsyncResult.loading([:user, :org]) immediately
      And on task completion both keys are updated atomically

    Scenario: User function returns invalid shape
      When the user function returns {:invalid, :shape}
      Then the runtime raises ArgumentError inside the task and writes Arbor.AsyncResult.failed(prior, {:exit, ...})

    Scenario: User function returns explicit error
      When the user function returns {:error, :unauthorized}
      Then ctx.assigns.<key> becomes Arbor.AsyncResult.failed(prior, {:error, :unauthorized})

  Rule: start_async routes results to handle_async; AsyncResult is not auto-written

    Scenario: Result delivered to handle_async
      Given a store implements handle_async(:warm_cache, result, ctx)
      When the application calls start_async(ctx, :warm_cache, fn -> Cache.warm() end)
      Then the runtime spawns a task and tracks it under name :warm_cache
      And on completion handle_async(:warm_cache, {:ok, val}, ctx) is invoked

    Scenario: No automatic AsyncResult assignment
      When the application calls start_async(ctx, :warm_cache, fn -> ... end)
      Then ctx.assigns is unchanged by the call
      And the client sees no AsyncResult unless the application manually writes one in handle_async

  Rule: handle_async must return {:noreply, ctx}

    Scenario: Successful return
      When handle_async(:foo, {:ok, val}, ctx) returns {:noreply, updated_ctx}
      Then the runtime accepts the new ctx and triggers a render cycle

    Scenario: Other return shapes raise
      When handle_async/3 returns anything other than {:noreply, ctx}
      Then the runtime raises with a "bad callback response" error

  Rule: cancel_async actively terminates a task and writes failed when called via AsyncResult variant

    Scenario: Cancel by AsyncResult sets failed before killing the task
      When the application calls cancel_async(ctx, %AsyncResult{loading: [:profile]} = ar, :user_navigated_away)
      Then ctx.assigns.profile is updated to Arbor.AsyncResult.failed(ar, {:exit, :user_navigated_away})
      And the runtime kills the associated task pid

    Scenario: Cancel by key kills the task and lets DOWN drive the failed write
      When the application calls cancel_async(ctx, :profile, :user_navigated_away)
      Then the runtime kills the associated task pid
      And the resulting :DOWN message triggers ctx.assigns.profile = Arbor.AsyncResult.failed(prior, {:exit, :user_navigated_away})

  Rule: assign_async :reset cancels the prior task before re-emitting loading

    Scenario: Reset all keys
      Given the prior assign_async for [:user, :org] is still in flight
      When the application calls assign_async(ctx, [:user, :org], fun, reset: true)
      Then the prior task is cancelled
      And both keys re-emit Arbor.AsyncResult.loading([:user, :org])

    Scenario: Reset subset of keys
      Given the prior assign_async for [:user, :org] is still in flight
      When the application calls assign_async(ctx, [:user, :org], fun, reset: [:user])
      Then the prior task is cancelled
      And :user re-emits Arbor.AsyncResult.loading; :org preserves its prior loading metadata

    Scenario: No reset preserves prior result during reload
      Given ctx.assigns.profile is %AsyncResult{ok?: true, result: prior_data}
      When the application calls assign_async(ctx, :profile, fun) without :reset
      Then ctx.assigns.profile becomes Arbor.AsyncResult.loading(prior_async_result)
      And the prior result remains observable via the loading struct's preserved fields

  Rule: Tasks are linked to the page runtime; runtime exit kills tasks; default supervisor is Arbor.AsyncSupervisor

    Scenario: Runtime exits
      Given async tasks are running
      When the page runtime exits
      Then all tasks linked to it exit with it
      And no orphan task survives

    Scenario: Custom supervisor
      When the application passes :supervisor to assign_async or start_async
      Then the task starts under that supervisor instead of Arbor.AsyncSupervisor

  Rule: A second start_async with the same name silently overwrites the prior tracked ref

    Scenario: Old task lazy-discards
      Given start_async(ctx, :foo, task_a) is in flight
      When the application calls start_async(ctx, :foo, task_b) before task_a completes
      Then runtime tracking switches to task_b's ref
      And task_a continues running but its result is discarded on arrival

  Rule: Cancel-vs-completion races resolve first-to-arrive-wins via ref-prune

    Scenario: Result wins
      Given a task is cancellable and nearly complete
      When the result message reaches the runtime before the cancel signal
      Then the runtime writes ok and prunes the ref
      And the subsequent cancel finds no entry and is a no-op

    Scenario: Cancel wins
      Given the runtime processes the cancel before the task's result arrives
      Then the runtime kills the pid and writes failed
      And the late result message is dropped because the ref no longer matches

  Rule: A :timeout option terminates an overdue task and produces failed: {:exit, :timeout}

    Scenario: Timer fires before completion
      When the application calls assign_async(ctx, :profile, fun, timeout: 5_000)
      And the task does not complete within 5 seconds
      Then the runtime kills the task pid
      And ctx.assigns.profile becomes Arbor.AsyncResult.failed(prior, {:exit, :timeout})

    Scenario: Task completes before timer fires
      When a task with timeout: 5_000 completes in 2 seconds
      Then the timer is cancelled
      And ctx.assigns.<key> reflects the normal ok or failed result

  Rule: Result classification on the wire AsyncResult is deterministic

    Scenario Outline: Failure event mapping
      Given a task encounters <event>
      Then ctx.assigns.<key> is updated to <terminal_state>

      Examples:
        | event                                      | terminal_state                        |
        | user fun returns {:ok, val}                | ok?: true, result: val                |
        | user fun returns {:error, reason}          | failed: {:error, reason}              |
        | task raises an exception                   | failed: {:exit, {reason, stacktrace}} |
        | task throws                                | failed: {:exit, {{:nocatch, ...}, stacktrace}} |
        | task process exits with reason r          | failed: {:exit, r}                    |
        | timeout fires                              | failed: {:exit, :timeout}             |
        | cancel_async with reason r                 | failed: {:exit, r}                    |

  Rule: A store node disappearing does not actively cancel its async tasks; results are lazily discarded

    Scenario: Child unmounted mid-task
      Given a child store has issued assign_async
      When the parent's next render no longer includes the child
      Then the child's task continues running
      And on completion the runtime checks the registry
      And finding the originating node absent, the runtime emits [:arbor, :async, :lazy_discard] and writes nothing to assigns

  Rule: AsyncResult.of(T) is a compile-time typespec marker

    Scenario: Field declaration
      When a store declares field :profile, AsyncResult.of(UserProfileState.t())
      Then codegen emits a TypeScript shape combining loading, ok?, result, failed
      And the runtime validator accepts %Arbor.AsyncResult{} or structurally-equivalent maps

  Rule: User functions warned for ctx capture (LV-aligned)

    Scenario: Closure captures ctx
      When a developer writes assign_async(ctx, :foo, fn -> ctx.assigns.bar end)
      Then the compile-time validator emits a warning recommending an explicit local binding before the fn

  Rule: AsyncResult flows through JSON Patch like ordinary maps

    Scenario: AsyncResult transitions on the wire
      Given ctx.assigns.profile transitions loading -> ok -> loading -> ok
      Then patch envelopes contain replace ops at /profile/loading, /profile/ok, /profile/result
      And the wire shape is the JSON-serialized AsyncResult struct

  Rule: handle_async/3 exceptions are caught; runtime survives

    Scenario: handle_async raises
      Given handle_async(:foo, {:ok, val}, ctx) raises a KeyError
      Then the runtime catches the exception
      And emits [:arbor, :async, :exception] with kind, reason, stacktrace
      And the runtime continues to process subsequent messages
      And ctx.assigns is not modified for that cycle

  Rule: Async telemetry is an Arbor extension over LV

    Scenario Outline: Lifecycle event surface
      When the runtime processes an async event
      Then it emits a telemetry event of name "<event>"
      With metadata including page_id, path, name (or keys), kind (assign or start)

      Examples:
        | event                        |
        | [:arbor, :async, :start]     |
        | [:arbor, :async, :stop]      |
        | [:arbor, :async, :exception] |
        | [:arbor, :async, :cancel]    |
        | [:arbor, :async, :lazy_discard] |

  Rule: Mount-time assign_async produces loading state in the first envelope

    Scenario: Mount calls assign_async
      Given mount(ctx) calls assign_async(ctx, :profile, fun)
      When the first patch envelope is emitted
      Then the value at /profile in the initial replace is %{loading: [:profile], ok?: false, result: nil, failed: nil}
      And a subsequent envelope's ops update /profile/ok and /profile/result on completion
