@replication @json-patch-diff
Feature: JSON Patch Diff and Replication
  As a connected client
  I want minimal RFC 6902 patches that describe exactly what changed in the server's resolved render output
  So that I can keep my local state in sync with monotonic versioning and predictable recovery

  Background:
    Given a connected client
    And a page runtime mounted on the client's transport session

  Rule: A render cycle that changes the resolved output produces exactly one patch envelope

    Scenario: Mutating handler causes one patch
      When a handler mutates ctx.assigns and returns
      Then the runtime computes the diff between previous and next resolved root output
      And emits exactly one patch envelope to the transport

  Rule: A render cycle whose resolved output is unchanged emits no patch envelope

    Scenario: Handler returns ctx unchanged
      When a handler returns {:noreply, ctx} without mutating ctx.assigns
      Then no patch envelope is sent

  Rule: The patch envelope is {type, base_version, version, ops, stream_ops}

    Scenario: Envelope shape after a state change
      When the runtime emits a patch
      Then the envelope contains type "patch"
      And it contains base_version equal to the previous version
      And it contains version equal to base_version + 1
      And it contains ops as an RFC 6902 op array
      And it contains stream_ops as an array (defined by streams/lifecycle)

  Rule: ops array uses only add, remove, and replace; move, copy, and test are not emitted

    Scenario Outline: Allowed ops
      When the diff engine emits an op
      Then the op kind is one of "<allowed>"
      And the op kind is not one of "move", "copy", or "test"

      Examples:
        | allowed                  |
        | add, remove, or replace  |

    Scenario: Reorder of a keyed list does not use move
      Given an array reorders such that elements stay length-equal but change positions
      When the diff engine emits ops for that change
      Then it produces only replace ops at affected indices
      And it never emits a move op

  Rule: All path values are JSON Pointer strings

    Scenario: Path encoding uses RFC 6901
      When an op references a field literally named "a/b"
      Then the op's path encodes the slash as "~1"
      And path values "/" and "~" produce the standard escapes via the runtime's JSON Pointer library
      And store authors do not assemble paths manually

  Rule: The page runtime maintains a single monotonic version counter starting at 0

    Scenario: Version increments by 1 per emitted envelope
      Given the page runtime has emitted patches at versions 1, 2, and 3
      When the next envelope is emitted
      Then its base_version is 3 and its version is 4

    Scenario: Reconnect resets the counter to 0
      Given a fresh page runtime mounts after a transport reconnect
      Then its version counter starts at 0
      And the first patch envelope after the fresh mount uses base_version: 0 and version: 1
      And the client treats the reconnect as a clean slate

  Rule: Stream-typed fields are excluded from JSON Patch ops

    Scenario: Stream-typed field appears as empty array at initial delivery
      Given a store declares field :messages, stream(MessageState.t())
      When the first patch envelope is emitted
      Then the value at /messages in the initial replace is []

    Scenario: Subsequent ops never touch stream-typed paths
      Given streams/lifecycle delivers items via stream_ops
      When the runtime emits a patch envelope
      Then ops never contain any op whose path is at or inside a stream-typed field
      And stream content flows entirely through stream_ops

  Rule: The diff engine emits the structural minimal diff with no fallback to subtree replace

    Scenario: Bulk reorder of a 1000-element list
      When 600 of 1000 elements change in a list
      Then the runtime emits exactly the per-index ops the JSON-diff library produces
      And the runtime does not collapse them into a single subtree replace
      And there is no op-count threshold or byte threshold

    Scenario: Tiny scalar change
      When a single deeply nested string field changes
      Then the runtime emits a single replace op pointing at that field

  Rule: There is no application-level resync command; reconnect is the recovery path

    Scenario: Client suspects state divergence
      Given a client suspects it is out of sync with the server
      When the client wants to recover
      Then the client tears down the transport and reconnects
      And the fresh page runtime mounts and emits a first patch with replace at path ""
      And no arbor:request_resync command is defined or expected

  Rule: Initial state is delivered via the first patch envelope

    Scenario: First patch carries a full-root replace
      When the page runtime first mounts
      Then the first emitted patch envelope contains
        | field         | value                                              |
        | base_version  | 0                                                  |
        | version       | 1                                                  |
        | ops           | a single op {op: "replace", path: "", value: root} |
        | stream_ops    | the initial stream ops (defined by streams/lifecycle) |
      And no separate "snapshot" envelope type is emitted

  Rule: One render cycle produces one patch envelope; cycles are not coalesced

    Scenario: Two commands in quick succession
      When command A and command B run back-to-back on the same runtime
      Then each command produces its own render cycle
      And each render cycle that yields a non-empty diff emits its own patch envelope
      And the runtime does not batch two cycles into one envelope

  Rule: A patch envelope is one logical update; ops within it are applied in array order

    Scenario: Intermediate state during op application
      Given an envelope ops: [{op: "remove", path: "/a"}, {op: "add", path: "/b", value: 42}]
      When a client applies the ops in order
      Then between the two ops the client's local document momentarily lacks both keys
      And after applying both ops the client's state matches version

  Rule: Function values never appear in ops

    Scenario: Render-output validation gates functions
      Given render-contract Rule 10 forbids function references in resolved output
      When the diff engine runs
      Then it operates on JSON-serializable values only
      And no op carries a function reference

  Rule: A patch envelope is associated with a command reply only when one drove the cycle

    Scenario: Command-driven cycle
      When a command produces both a transport reply and a render-changing cycle
      Then the transport reply is delivered first
      And a separate patch push follows carrying the resulting envelope

    Scenario: Server-driven cycle
      When handle_async or handle_info drives a render-changing cycle
      Then no transport reply is associated with the resulting patch envelope
