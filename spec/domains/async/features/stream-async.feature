@async @stream-async
Feature: stream_async
  As a store author
  I want to launch a background task whose result populates a stream slot
  So that long, lazily-loaded collections deliver per-item ops with explicit loading-state on the wire

  Background:
    Given a connected client
    And a page runtime mounted on the client's transport session

  Rule: stream_async composes async lifecycle with the stream API

    Scenario: First call ensures both the AsyncResult assignment and the stream slot
      Given a store declares stream :messages, ...
      When the application calls stream_async(socket, :messages, fn -> {:ok, items} end)
      Then socket.assigns.messages is set to Arbor.AsyncResult.loading() synchronously
      And the stream slot named messages is initialized
      And a task is spawned linked to the page runtime under Arbor.AsyncSupervisor

  Rule: The user function returns {:ok, enumerable}, {:ok, enumerable, stream_opts}, or {:error, reason}

    Scenario: Items only
      When the user fun returns {:ok, [%Msg{id: 1}, %Msg{id: 2}]}
      Then on completion the runtime calls stream(socket, :messages, items, [])

    Scenario: Items with stream opts
      When the user fun returns {:ok, [%Msg{id: 1}], at: 0, limit: -100}
      Then on completion the runtime calls stream(socket, :messages, [msg], at: 0, limit: -100)

    Scenario: Explicit error
      When the user fun returns {:error, :rate_limited}
      Then socket.assigns.messages becomes Arbor.AsyncResult.failed(prior, {:error, :rate_limited})
      And the stream slot remains untouched

    Scenario: Invalid return shape
      When the user fun returns [%Msg{}] without the {:ok, ...} wrapper
      Then the runtime raises ArgumentError inside the task
      And socket.assigns.messages becomes Arbor.AsyncResult.failed(prior, {:exit, ...})

  Rule: A successful task atomically updates the AsyncResult to ok and seeds the stream

    Scenario: Single envelope captures both transitions
      When the task completes successfully with items [msg1, msg2]
      Then the next envelope contains JSON Patch ops at /messages/ok and /messages/loading reflecting AsyncResult transitions
      And the same envelope contains stream_ops with insert ops for each item
      And socket.assigns.messages.result is true (Arbor.AsyncResult.ok flag)

  Rule: Failure leaves the stream contents untouched

    Scenario: Failed task on a previously-populated stream
      Given the stream messages contains 50 items from an earlier successful load
      When a fresh stream_async call returns {:error, :network_failure}
      Then socket.assigns.messages becomes Arbor.AsyncResult.failed(prior, {:error, :network_failure})
      And the stream's previously delivered items remain on the client

  Rule: :reset cancels the prior task and re-emits Arbor.AsyncResult.loading; stream contents controlled by the user fn

    Scenario: Reset re-emits loading
      Given a prior stream_async task is in flight for :messages
      When the application calls stream_async(socket, :messages, fun, reset: true)
      Then the prior task is cancelled
      And socket.assigns.messages re-emits Arbor.AsyncResult.loading()

    Scenario: Stream reset only when the user fn returns it
      Given a stream_async with reset: true completes successfully
      When the user fun returns {:ok, items, reset: true}
      Then the resulting stream/4 call clears the stream and re-seeds with the new items

    Scenario: Stream not reset when the user fn does not request it
      Given a stream_async with reset: true completes successfully
      When the user fun returns {:ok, items} (no reset opt)
      Then the resulting stream/4 call seeds without clearing
      And the stream's prior items still exist alongside the new ones

  Rule: All other async lifecycle behaviors apply

    Scenario Outline: Inherited async behaviors
      Given a stream_async task is in flight for :messages
      When <event>
      Then <outcome>

      Examples:
        | event                                                 | outcome                                                            |
        | the task times out (with :timeout option)             | socket.assigns.messages becomes Arbor.AsyncResult.failed(prior, {:exit, :timeout}); stream untouched |
        | the application calls cancel_async(socket, :messages, r) | the task is killed; socket.assigns.messages becomes Arbor.AsyncResult.failed(prior, {:exit, r))     |
        | the task crashes                                      | socket.assigns.messages becomes Arbor.AsyncResult.failed(prior, {:exit, ...})                       |
        | the originating store node is unmounted               | the result is lazy-discarded; [:arbor, :async, :lazy_discard] is emitted                    |
        | a second stream_async is called for :messages         | the prior task is overwritten in tracking; only the latest task's result populates state    |

  Rule: stream_async requires a previously-declared stream slot

    Scenario: Calling stream_async on an undeclared name raises
      Given a store has no stream :messages declaration
      When the application calls stream_async(socket, :messages, fun)
      Then the runtime raises ArgumentError pointing at the missing declaration

  Rule: state do field type for stream_async-managed slots is composite

    Scenario: Composite typespec
      Given a store declares field :messages, AsyncResult.of(stream(MessageState.t()))
      Then the runtime accepts the value as a four-field AsyncResult whose result is true once populated
      And codegen emits a TypeScript composite shape combining AsyncResult and an items array

  Rule: reload_stream and stream_async serve complementary recovery paths

    Scenario: reload_stream silently refreshes without loading flash
      Given socket.assigns.messages is %AsyncResult{ok?: true, result: true}
      When the application calls reload_stream(socket, :messages)
      Then the runtime invokes reload_stream/2 to fetch new items
      And the resulting envelope contains stream_ops with reset and inserts
      And socket.assigns.messages remains %AsyncResult{ok?: true, result: true}
      And the client sees no loading flash

    Scenario: stream_async(reset: true) explicitly resets the loading indicator
      Given socket.assigns.messages is %AsyncResult{ok?: true, result: true}
      When the application calls stream_async(socket, :messages, fun, reset: true)
      Then socket.assigns.messages re-emits Arbor.AsyncResult.loading()
      And the client UI may show a loading indicator while the task runs
      And the task's result populates the stream as in a fresh load
