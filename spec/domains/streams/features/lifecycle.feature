@streams @lifecycle
Feature: Streams Lifecycle
  As a store author
  I want to declare stream-typed collections whose deltas the server emits as ordered ops without retaining the materialized list
  So that long, append-mostly collections do not load the server while the client owns full materialization

  Background:
    Given a connected client
    And a page runtime mounted on the client's transport session

  Rule: A store declares a stream slot via stream :name, T, opts inside state do

    Scenario: Custom item_key and limit
      Given a store declares state do stream :messages, MessageState.t(), item_key: &"msg-#{&1.id}", limit: -100 end
      Then the runtime records the item_key function and a limit of -100 for the messages stream

    Scenario: Default item_key depends on item id
      Given a store declares state do stream :songs, SongState.t() end
      When the runtime computes an item_key for an item with id "abc"
      Then the item_key is "songs-abc"

    Scenario: Default item_key and missing item id
      Given a store declares state do stream :songs, SongState.t() end
      When the application passes an item without an :id field
      Then the runtime raises an ArgumentError pointing at the failing call site

    Scenario: Duplicate stream name in one store
      Given a store source contains state do stream :messages, MessageState.t(), ... stream :messages, MessageState.t(), ... end
      When the project compiles
      Then the compiler reports a duplicate-stream error

  Rule: A stream-typed field in state do is the canonical wire surface

    Scenario: state declaration plus stream slot
      Given a store declares state do stream :messages, MessageState.t(), ... end
      Then the wire envelope emits stream content via stream_ops
      And the JSON Patch ops never touch /messages

  Rule: socket-pipe stream API mirrors Phoenix.LiveView (LV-aligned semantics)

    Scenario Outline: API surface
      When the application calls <call> on socket
      Then the runtime queues a corresponding pending op in the named stream

      Examples:
        | call                                          |
        | stream(:messages, items)                      |
        | stream(:messages, items, reset: true)         |
        | stream_configure(:messages, item_key: ...)    |
        | stream_insert(:messages, item)                |
        | stream_insert(:messages, item, at: 0)         |
        | stream_insert(:messages, item, limit: -100)   |
        | stream_delete(:messages, item)                |
        | stream_delete_by_item_key(:messages, "msg-1") |

    Scenario: Insert never inspects current contents server-side
      Given the application calls stream_insert(:messages, %{id: 1})
      When the application immediately calls stream_insert(:messages, %{id: 1, body: "edited"})
      Then both calls queue an insert op without consulting any server-side index
      And the client decides whether each op is an upsert or a fresh insert

    Scenario: Delete never inspects current contents server-side
      Given the stream has never been written to
      When the application calls stream_delete_by_item_key(:messages, "msg-1")
      Then a delete op is queued for "msg-1"
      And the runtime does not raise

  Rule: stream_configure is a lifetime gate — must precede the stream's first init

    Scenario: Configure after init raises
      Given the application has called stream_insert(:messages, msg) for the first time
      When the application later calls stream_configure(:messages, item_key: ...)
      Then the runtime raises

    Scenario: Configure before init applies overrides
      Given no insert has been queued for :messages
      When the application calls stream_configure(:messages, item_key: &("custom-" <> &1.id))
      And the application calls stream_insert(:messages, %{id: "1"})
      Then the queued insert op carries item_key "custom-1"

  Rule: Pending ops drain through the prune hook then the page server flush

    Scenario: A handler queues multiple ops
      Given a handler calls stream_insert(:messages, msg1) and stream_insert(:messages, msg2)
      When the handler returns and the page runtime renders
      Then exactly one envelope is emitted with stream_ops carrying both inserts in queue order
      And after the envelope is emitted no pending stream ops remain on the LiveStream

  Rule: After flush the runtime forgets stream contents (server-side state is purely deltas)

    Scenario: Server memory after a 1000-item flush
      When the application seeds 1000 items into a stream and the runtime flushes
      Then the LiveStream's inserts/deletes/reset? are empty
      And the runtime never built an ordered list of item_keys server-side

  Rule: Initial state delivery splits stream fields between ops and stream_ops

    Scenario: Mount-time seed
      Given mount/1 calls stream(socket, :messages, [%Msg{id: 1}, %Msg{id: 2}])
      When the first patch envelope is emitted
      Then the envelope's ops contain a single replace at path "" whose value has messages: {"__musubi_stream__": "messages"}
      And the envelope's stream_ops contain one insert per seed item in seed order

  Rule: Stream-only render cycles still emit envelopes

    Scenario: A handler that only modifies a stream
      When a handler calls stream_insert(:messages, msg) and otherwise leaves socket.assigns unchanged
      Then the runtime emits one envelope with ops: [] and stream_ops: [<the insert>]

    Scenario: A render cycle with no changes at all emits nothing
      When a handler returns socket unchanged and queues no stream ops
      Then the runtime emits no envelope

  Rule: A patch envelope is one logical update; stream_ops apply in array order after ops

    Scenario: Reset followed by inserts
      Given an envelope's stream_ops are [{reset ...}, {insert ...}, {insert ...}]
      When the client applies the envelope
      Then it first applies all ops, then applies stream_ops in array order
      And the reset clears the local stream before subsequent inserts populate it

  Rule: :limit is per-op on the wire; the client trims (server does not)

    Scenario: Insert carries a per-op limit field
      When the application calls stream_insert(:messages, item, limit: -100)
      Then the queued insert op records limit: -100 on the wire
      And the server does not maintain an item_key index to trim against

  Rule: :at applies the standard LV positions

    Scenario Outline: Position semantics
      When the application calls stream_insert(:messages, item, at: <at>)
      Then the queued insert records position <at>
      And the client materializes the item at position <effect>

      Examples:
        | at | effect                                       |
        | -1 | append (end of list)                         |
        |  0 | prepend (start of list)                      |
        |  3 | inserted at index 3 in the materialized list |

  Rule: Stream owner unmount cleans up implicitly via JSON Patch remove

    Scenario: Parent stops rendering the owning store
      Given a parent store renders child(MessagesStore, id: "messages") in cycle N
      When cycle N+1 omits that child
      Then the JSON Patch ops produce a remove or replace at the corresponding path
      And the client materializer drops local stream state for that path
      And the runtime does not emit a separate reset op for the disappeared stream

  Rule: There is no dedicated reload mechanism — refresh via stream/4 with reset: true

    Scenario: Application has fresh items and re-seeds silently
      Given socket.assigns has the freshly fetched items in hand
      When the handler calls stream(socket, :messages, items, reset: true)
      Then the resulting envelope's stream_ops contain a reset followed by one insert per item
      And no AsyncResult is touched
      And the client sees no loading flash

  Rule: Wire op shape carries (op, stream, ref, store_id, ...) — LV-aligned plus owning store path

    Scenario: Insert op fields
      When the runtime emits an insert op
      Then the op map contains op: "insert", stream: <stream name as string>, ref: <stream ref as string>, store_id: <owning store path>, item_key, at, item, limit

    Scenario: Delete op fields
      When the runtime emits a delete op
      Then the op map contains op: "delete", stream: <stream name as string>, ref: <stream ref as string>, store_id: <owning store path>, item_key

    Scenario: Reset op fields
      When the runtime emits a reset op
      Then the op map contains op: "reset", stream: <stream name as string>, ref: <stream ref as string>, store_id: <owning store path>

    Scenario: stream_configure is server-side only
      When the application calls stream_configure(:messages, item_key: ..., limit: -100)
      Then no configure op appears on the wire
      And the next insert uses the configured item_key function and default limit
