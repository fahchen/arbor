@runtime @command-routing
Feature: Command Routing
  As a connected client
  I want my commands to be routed, validated, authorized, dispatched, and replied to with structured outcomes
  So that server-side state changes are predictable, type-safe, and observable

  Background:
    Given a connected client
    And a page runtime mounted on the client's transport session

  Rule: Commands route by path to the addressed store node

    Scenario: Routing to the root store
      Given the page runtime owns a root store that declares the command "reload_products"
      When the client sends a command targeting path [] with name "reload_products"
      Then the runtime dispatches the command to the root store's handler

    Scenario: Routing to a nested child store
      Given the root store renders a child store under field "filters"
      And the child store declares the command "change_query"
      When the client sends a command targeting path ["filters"] with name "change_query"
      Then the runtime dispatches the command to the filters store's handler

    Scenario: Routing to a child of a keyed list
      Given the root store renders a list of product card stores keyed by id
      And a product card store keyed "prod_123" declares the command "select"
      When the client sends a command targeting path ["products", "prod_123"] with name "select"
      Then the runtime dispatches the command to the matching product card store's handler

  Rule: A path that does not resolve to a mounted store is rejected without invoking any handler

    Scenario: Path no longer present after a render cycle
      Given the most recent render cycle no longer mounts a child at path ["notifications"]
      When the client sends a command targeting path ["notifications"] with name "mark_all_read"
      Then no handler runs
      And the client receives an error reply with category "unknown_path"
      And no patch push follows

  Rule: A store rejects commands it has not declared

    Scenario: Command name absent from the addressed store's declarations
      Given the addressed store declares only the command "select"
      When the client sends a command with name "delete" to that store
      Then no handler runs
      And the client receives an error reply with category "unknown_command"

  Rule: A command's payload is validated against the declared schema before the handler runs

    Scenario: Payload conforms to the declared schema
      Given the store declares "change_query" with payload field "query" typed as string
      When the client sends a command with payload {"query": "shirt"}
      Then payload validation succeeds
      And the handler runs

    Scenario: Payload violates a declared field type
      Given the store declares "change_query" with payload field "query" typed as string
      When the client sends a command with payload {"query": 42}
      Then payload validation fails before any handler runs
      And the client receives an error reply with category "invalid_payload"
      And the error reply lists the failing field path "/query"

  Rule: An error reply uses a discrete category enum plus structured detail

    Scenario Outline: Error categories surfaced on the wire
      Given a command that is rejected for reason <reason>
      When the runtime emits the error reply
      Then the reply status is "error"
      And the reply payload includes a category equal to "<category>"
      And the reply payload includes structured detail describing <reason>

      Examples:
        | reason                              | category         |
        | path not in the store registry      | unknown_path     |
        | command not declared on the store   | unknown_command  |
        | payload fails schema validation     | invalid_payload  |
        | authorization denied                | unauthorized     |
        | a custom hook halt with error | hook_halt  |

    Scenario: Handler-controlled business failures arrive as ok status
      Given the handler returns {:reply, %{ok: false, error: "out_of_stock"}, ctx}
      When the runtime delivers the outcome
      Then the reply status is "ok"
      And the reply payload contains {"ok": false, "error": "out_of_stock"}
      And the reply payload does not include an error category

  Rule: Authorization runs in the command pipeline and may halt before the handler runs

    Scenario: Authorization hook halts an unauthorized command
      Given the addressed store attaches an authorization hook for ability "checkout" during mount
      And the policy denies "checkout" for the current actor
      When the client sends a command requiring "checkout"
      Then the handler does not run
      And no state mutation is committed
      And no patch push follows
      And the client receives an error reply with category "unauthorized"

  Rule: Authorization failure always produces a hard error reply with no silent downgrade

    Scenario: Denied command never returns ok
      Given a denied command from an unauthorized actor
      When the runtime emits the outcome
      Then the reply status is "error"
      And the reply payload category is "unauthorized"
      And the runtime does not return a synthetic ok no-op

  Rule: A successful handler returns either {:noreply, ctx} or {:reply, payload, ctx}

    Scenario: Handler chooses {:noreply, ctx}
      When the handler completes with {:noreply, ctx}
      Then the client receives a reply with status "ok" and an empty payload
      And the resulting state mutations are observable through the next patch push

    Scenario: Handler chooses {:reply, payload, ctx}
      When the handler completes with {:reply, %{order_id: "ord_42"}, ctx}
      Then the client receives a reply with status "ok" and payload {"order_id": "ord_42"}
      And the resulting state mutations are observable through the next patch push

  Rule: A handler crash terminates the page runtime and the client reconnects via fresh mount

    Scenario: Handler raises during command execution
      When the handler raises an exception
      Then the page runtime exits
      And no error reply is sent for the crashing command
      And the supervisor restarts the runtime
      And the client transport observes a connection drop
      And the next reconnect mounts a fresh page runtime whose mount/1 re-initializes state from scratch

  Rule: Commands are serialized per page runtime

    Scenario: Two commands arriving back to back
      Given the runtime is processing command A
      When command B arrives before command A's outcome is delivered
      Then command B waits until command A's reply, patch push, and effects have completed
      And only then does command B begin

  Rule: Each command receives exactly one transport reply correlated to its source push

    Scenario: Successful command produces a single ok reply and a separate patch push
      When the runtime completes a state-mutating command
      Then the client receives exactly one reply with status "ok"
      And a separate patch push delivers the state diff
      And the reply does not embed the state diff

    Scenario: Rejected command produces a single error reply with no patch push
      When the runtime rejects a command
      Then the client receives exactly one reply with status "error"
      And no patch push follows

  Rule: The transport preserves command order and reply correlation

    Scenario: Replies arrive in the order commands were sent
      Given the client sends command A then command B over the same transport session
      Then the runtime processes A before B
      And the reply for A reaches the client before the reply for B
      And the runtime maintains no application-layer sequence number or dedup table

  Rule: A successful command's outcome is delivered as reply, then patch push, then effects

    Scenario: Outcome ordering for a command that broadcasts
      Given a handler that mutates state and queues an outbound message
      When the handler completes successfully
      Then the transport reply is delivered first
      And a patch push follows carrying the state diff
      And the outbound message is published last

  Rule: Path resolution consults the runtime's authoritative registry of mounted store nodes

    Scenario: A queued command targets a node unmounted by an earlier command
      Given an earlier command unmounted the child at path ["notifications"]
      And the registry has been updated by that command's render cycle
      When the next queued command targets path ["notifications"]
      Then the runtime rejects the command with category "unknown_path"

  Rule: Hooks run in attachment order

    Scenario: Hook order matches the order they were attached
      Given a store attaches a :before_command hook with id :validate then a :before_command hook with id :authorize during mount
      When the runtime executes a command on that store
      Then :validate runs before :authorize
      And the handler runs after both hooks

    Scenario: A root-attached hook runs before a child-attached hook
      Given the root page store attaches a :before_command hook in mount
      And the addressed child store also attaches its own :before_command hook in mount
      When the runtime executes a command on the child
      Then the root hook runs first
      Then the child hook runs after the root hook
      And the handler runs last

  Rule: System commands occupy a reserved name prefix and share the main pipeline

    Scenario: System command flows through the standard pipeline
      When the client sends a command named "arbor:request_stream_reload"
      Then the runtime routes, validates, and authorizes the command using the same pipeline as user commands
      And user-attached hooks observe the system command

    Scenario: User-defined command using the reserved prefix is rejected at compile time
      Given a store declares a command named "arbor:something"
      When the project compiles
      Then the compiler reports an error about the reserved namespace

  Rule: A :before_command hook may halt with a reply and short-circuit the pipeline

    Scenario: Hook continues the pipeline
      Given a tracing :before_command hook that returns {:cont, ctx}
      When the runtime processes a command
      Then the pipeline continues to the next hook

    Scenario: Hook halts without a reply
      Given a feature-flag gate hook that returns {:halt, ctx}
      When the runtime processes a command
      Then the addressed handler does not run
      And the runtime delivers a default ok reply with an empty payload

    Scenario: Hook halts with a custom reply
      Given a feature-flag gate hook that returns {:halt, %{ok: false, reason: "feature_disabled"}, ctx}
      When the runtime processes a command
      Then the addressed handler does not run
      And the client receives a reply with status "ok" and payload {"ok": false, "reason": "feature_disabled"}

  Rule: A page runtime is bound 1:1 to its transport session

    Scenario: Transport closes
      When the transport session closes
      Then the page runtime terminates immediately
      And no in-flight reply or patch is buffered for delivery

  Rule: A reconnecting client mounts a fresh page runtime whose mount/1 re-initializes state from scratch

    Scenario: Client reconnects after a transport drop
      Given the previous page runtime exited due to a transport drop
      When the client reconnects
      Then a fresh page runtime mounts
      And the runtime's mount callback re-runs from scratch
      And no in-flight commands from the previous runtime are re-executed
      And the application is responsible for any session-restore behavior via its own mount logic or hook-based persistence pattern

  Rule: Outcomes emitted to a closed transport are silently discarded

    Scenario: Reply produced after the transport closed
      Given the transport closed before the handler completed
      When the handler completes its outcome
      Then the runtime does not retry, buffer, or persist the reply, patch, or effects
      And the client must establish a new session to observe current state

  Rule: Every command execution emits a telemetry span

    Scenario: Successful command emits start and stop events
      When the runtime processes a command successfully
      Then a telemetry event is emitted at command start
      And a telemetry event is emitted at command stop with metadata indicating status "ok"

    Scenario: Rejected command surfaces the rejection category in the stop event
      When the runtime rejects a command for an unauthorized actor
      Then the stop telemetry event metadata includes status "error" and error_category "unauthorized"
      And no separate "rejected" event is emitted

    Scenario: Handler crash emits an exception event
      When the handler raises during command execution
      Then a telemetry exception event is emitted
      And the metadata includes the exception kind, reason, and a stacktrace

  Rule: Telemetry metadata stays minimal and excludes payload contents

    Scenario: Stop event metadata fields
      When the runtime emits a command stop event
      Then the metadata includes page_id, path, command, status, and (when status is error) error_category
      And the metadata does not include the command payload contents
      And the metadata does not include user identifiers by default

  Rule: attach_hook is callable wherever ctx is in scope

    Scenario: Hook attached during a handler
      Given mount has already completed
      When a handler calls attach_hook(ctx, :one_shot, :before_command, fn)
      Then the hook is registered and runs for subsequent commands

    Scenario: Re-attaching the same id on the same stage raises
      Given a hook with id :audit is already attached on stage :before_command
      When code calls attach_hook(ctx, :audit, :before_command, fn) again without first detaching
      Then the runtime raises ArgumentError

  Rule: Each store maintains its own hook table

    Scenario: Child-attached hook fires only for that node's commands
      Given a child store attaches a :before_command hook during its mount
      When the client sends a command to a sibling store
      Then the child's hook does not run

    Scenario: Root-attached hook fires for every command
      Given the root page store attaches a :before_command hook during its mount
      When the client sends a command to any descendant store
      Then the root hook runs

  Rule: detach_hook silently no-ops when the hook is absent

    Scenario: Detaching a hook that was never attached
      When code calls detach_hook(ctx, :nonexistent, :before_command)
      Then the call returns the unchanged ctx
      And no error is raised

  Rule: Arbor does not define a built-in pub/sub layer

    Scenario: Stores subscribe to external message sources directly
      When a store wants to receive cross-page or external updates
      Then the store calls the application's pub/sub subscribe API directly inside its mount callback
      And the store handles inbound messages via handle_info(msg, ctx)
      And the runtime exposes no Arbor-specific subscribe macro or broadcast helper

  Rule: handle_info messages share the runtime's processing queue with commands

    Scenario: Command and message arrive concurrently
      Given the runtime is idle
      When a command and a server-side message arrive within microseconds of each other
      Then the runtime processes them in arrival order
      And neither preempts the other mid-cycle

  Rule: handle_info returns {:noreply, ctx} only and produces no transport reply

    Scenario: handle_info that mutates state
      When a server-side message triggers handle_info that mutates assigns
      Then no transport reply envelope is sent
      And a single patch push delivers the resulting state diff

    Scenario: handle_info that does not change rendered output
      When a server-side message triggers handle_info that leaves the rendered output unchanged
      Then no transport reply envelope is sent
      And no patch push is emitted
