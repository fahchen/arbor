@streams @lifecycle
Feature: Streams Lifecycle
  As a store author
  I want to declare stream-typed collections whose item values the server emits as ordered ops without retaining them in memory
  So that long, append-mostly collections do not load the server while the client owns full materialization

  Background:
    Given a connected client
    And a page runtime mounted on the client's transport session

  Rule: A store declares a stream slot via stream :name, opts

    Scenario: Custom dom_id and limit
      Given a store declares stream :messages, dom_id: &"msg-#{&1.id}", limit: -100
      Then the runtime records the dom_id function and a limit of -100 for the messages stream

    Scenario: Default dom_id depends on item id
      Given a store declares stream :songs without :dom_id
      When the runtime computes a dom_id for an item with id "abc"
      Then the dom_id is "songs-abc"

    Scenario: Default dom_id and missing item id
      Given a store declares stream :songs without :dom_id
      When the application passes an item without an :id field
      Then the runtime raises an ArgumentError pointing at the failing call site

    Scenario: Duplicate stream name in one store
      Given a store source contains stream :messages, ... twice
      When the project compiles
      Then the compiler reports a duplicate-stream error

  Rule: A stream-typed field in state do is the canonical wire surface

    Scenario: state declaration plus stream slot
      Given a store declares stream :messages, ...
      And the store declares field :messages, stream(MessageState.t())
      Then the wire envelope emits stream content via stream_ops
      And the JSON Patch ops never touch /messages

  Rule: ctx-pipe stream API mirrors Phoenix.LiveView

    Scenario Outline: API surface
      When the application calls <call> on ctx
      Then the runtime queues a corresponding pending op in the named stream

      Examples:
        | call                                        |
        | stream(:messages, items)                    |
        | stream(:messages, items, reset: true)       |
        | stream_configure(:messages, dom_id: ...)    |
        | stream_insert(:messages, item)              |
        | stream_insert(:messages, item, at: 0)       |
        | stream_insert(:messages, item, limit: -100) |
        | stream_insert(:messages, item, update_only: true) |
        | stream_delete(:messages, item)              |
        | stream_delete_by_dom_id(:messages, "msg-1") |

    Scenario: Insert is upsert by dom_id
      Given the stream already contains an item at dom_id "msg-1"
      When the application calls stream_insert(:messages, %{id: 1, body: "edited"})
      Then the queued op replaces the item in place
      And the stream length does not change

    Scenario: update_only true on a missing dom_id is a no-op
      Given the stream does not contain dom_id "msg-9"
      When the application calls stream_insert(:messages, %{id: 9}, update_only: true)
      Then no op is queued for that call

  Rule: stream_configure must precede other stream ops for the same name in one handler

    Scenario: Configure after insert raises
      Given a handler queues stream_insert(:messages, msg)
      When the same handler subsequently calls stream_configure(:messages, dom_id: ...)
      Then the runtime raises

  Rule: Pending ops flush once per handler invocation

    Scenario: A handler queues multiple ops
      Given a handler calls stream_insert(:messages, msg1) and stream_insert(:messages, msg2)
      When the handler returns
      Then exactly one envelope is emitted with stream_ops carrying both inserts in queue order
      And after the envelope is emitted no pending stream ops remain

    Scenario: Pending ops do not survive across handlers
      Given handler A queued stream ops and finished
      When handler B begins for the next message
      Then handler B starts with no pending stream ops from handler A

  Rule: After flush the runtime forgets stream values; only the dom_id index is retained

    Scenario: Server memory after a 1000-item flush
      When the application seeds 1000 items into a stream
      Then the runtime retains only the ordered list of dom_ids server-side
      And the runtime does not retain item bodies

  Rule: Initial state delivery splits stream fields between ops and stream_ops

    Scenario: Mount-time seed
      Given mount/1 calls stream(ctx, :messages, [%Msg{id: 1}, %Msg{id: 2}])
      When the first patch envelope is emitted
      Then the envelope's ops contain a single replace at path "" whose value has messages: []
      And the envelope's stream_ops contain one insert per seed item in seed order

  Rule: Stream-only render cycles still emit envelopes

    Scenario: A handler that only modifies a stream
      When a handler calls stream_insert(:messages, msg) and otherwise leaves ctx.assigns unchanged
      Then the runtime emits one envelope with ops: [] and stream_ops: [<the insert>]

    Scenario: A render cycle with no changes at all emits nothing
      When a handler returns ctx unchanged and queues no stream ops
      Then the runtime emits no envelope

  Rule: A patch envelope is one logical update; stream_ops apply in array order after ops

    Scenario: Reset followed by inserts
      Given an envelope's stream_ops are [{configure ...}, {reset ...}, {insert ...}, {insert ...}]
      When the client applies the envelope
      Then it first applies all ops, then applies stream_ops in array order
      And the reset clears the local stream before subsequent inserts populate it

  Rule: :limit is re-evaluated only when the dom_id index grows

    Scenario: Upsert at the limit
      Given a stream has 100 items and limit: -100
      When the application upserts an existing dom_id
      Then the envelope's stream_ops contain only the insert
      And no delete is emitted

    Scenario: New insert at the limit
      Given a stream has 100 items and limit: -100
      When the application inserts a new dom_id
      Then the envelope's stream_ops contain the insert
      And the envelope contains a delete for the previously-trimmed-out dom_id

  Rule: :at applies the standard LV positions

    Scenario Outline: Position semantics
      When the application calls stream_insert(:messages, item, at: <at>)
      Then the queued insert records position <at>
      And the client materializes the item at position <effect>

      Examples:
        | at | effect                                    |
        | -1 | append (end of list)                      |
        |  0 | prepend (start of list)                   |
        |  3 | inserted at index 3 in the materialized list |

  Rule: Stream owner unmount cleans up implicitly via JSON Patch remove

    Scenario: Parent stops rendering the owning store
      Given a parent store renders child(MessagesStore, id: "messages") in cycle N
      When cycle N+1 omits that child
      Then the JSON Patch ops produce a remove or replace at the corresponding path
      And the client materializer drops local stream state for that path
      And the runtime does not emit a separate reset op for the disappeared stream

  Rule: Stream reload is application-driven via ctx |> reload_stream(name)

    Scenario: Application requests a reload
      Given a store implements reload_stream(:messages, ctx) returning {:ok, items}
      When a handler calls reload_stream(ctx, :messages)
      Then the runtime invokes the store's reload_stream callback
      And the envelope's stream_ops contain a reset followed by one insert per returned item

    Scenario: Runtime never auto-invokes reload_stream
      Given the runtime is in any state (mount, command, async, info, reconnect)
      Then the runtime does not auto-invoke reload_stream/2
      And reload happens only when the application calls the helper
