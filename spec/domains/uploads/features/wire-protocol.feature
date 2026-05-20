@uploads @wire-protocol
Feature: Upload Wire Protocol
  As a runtime
  I want upload state to ship through an independent upload_ops stream
  So that high-frequency progress updates do not pollute change tracking or trigger main-store re-renders

  Background:
    Given a connected client
    And a page runtime with upload :avatar declared

  Rule: The envelope carries a third op array named upload_ops

    Scenario: Envelope wire shape
      When the runtime emits an envelope after a chunk arrival
      Then the envelope JSON has keys "type", "base_version", "version", "ops", "stream_ops", and "upload_ops"

    Scenario: First envelope carries marker plus config op
      Given the initial mount has just completed
      When the runtime emits the first envelope
      Then "ops" contains a replace of the root with the upload marker injected
      And "upload_ops" contains one {op: "config", upload: "avatar", store_id: [], config: %{...}} op

  Rule: upload_ops op vocabulary

    Scenario Outline: Op kinds carried in upload_ops
      When the runtime needs to deliver <kind>
      Then the envelope carries an op of shape <shape>

      Examples:
        | kind                          | shape                                                                                     |
        | initial config                | {op: "config",   upload, store_id, config}                                                |
        | new accepted entry            | {op: "add",      upload, store_id, ref, entry}                                            |
        | per-chunk progress            | {op: "progress", upload, store_id, ref, progress}                                         |
        | entry completion              | {op: "complete", upload, store_id, ref}                                                   |
        | per-entry validation failure  | {op: "error",    upload, store_id, ref, error: %{code, message}}                          |
        | client or server cancel       | {op: "cancel",   upload, store_id, ref}                                                   |
        | full upload reset             | {op: "reset",    upload, store_id}                                                        |

  Rule: store_id on each upload_op matches the owning store's path

    Scenario: Root store upload
      Given the upload is declared on the root store
      Then every upload_op for that upload carries store_id []

    Scenario: Child store upload
      Given the upload is declared on a child store at path ["form"]
      Then every upload_op for that upload carries store_id ["form"]

  Rule: JSON Patch ops never carry upload entry content

    Scenario: Progress mutation does not appear in ops
      Given an in-progress entry receives 10 chunks
      Then the resulting ops list has no entries touching paths under /avatar/entries
      And upload_ops contains progress ops for each chunk (subject to coalescing)

  Rule: An envelope emits when ops OR stream_ops OR upload_ops is non-empty

    Scenario: Cycle with only upload_ops mutation
      Given a cycle produces no JSON Patch ops and no stream_ops
      And the cycle produces at least one upload_op
      Then the runtime emits an envelope containing those upload_ops

    Scenario: Fully empty cycle
      Given a cycle produces no ops, no stream_ops, and no upload_ops
      Then the runtime emits no envelope

  Rule: Drain coalesces consecutive progress ops on the same {store_id, upload, ref}

    Scenario: Three progress events in one drain cycle
      Given three progress events at 10, 20, 30 arrive within a single drain window for {store_id [], upload "avatar", ref "e_001"}
      When the runtime drains the queue
      Then the envelope upload_ops contains exactly one progress op with progress 30

    Scenario: Throttle limits emission rate
      Given continuous progress events for entry e_001
      Then the runtime emits progress ops at no more than 10 per second by default

    Scenario: Throttle is per-entry
      Given progress events for two entries e_001 and e_002 within the same drain window
      Then both entries can produce one progress op each in that window

  Rule: Upload mutation does not pollute __changed__ for other assigns

    Scenario: A chunk arrival does not mark unrelated assigns dirty
      Given socket.assigns has a :title field
      When a chunk arrives for upload :avatar
      Then socket.assigns.__changed__ does not include :title
      And the store's render/1 is not invoked solely on chunk arrival

  Rule: Server-private upload fields never appear in wire output

    Scenario: Entry struct serialization
      Given an upload entry has path, token, store_pid, bytes_written, external_meta, and preflighted_at server-only fields
      When the runtime serializes the entry for wire delivery
      Then the wire entry contains only ref, client_name, client_size, client_type, progress, status, and errors

  Rule: Error message strings are scrubbed of infrastructure detail

    Scenario: Disk write failure
      Given the server fails to write a chunk because the temp file is unwritable
      Then the emitted {op: "error"} carries a stable code and a message that contains no file path
      And the message contains no pid string
      And the message contains no token fragment

  Rule: External upload progress is reflected as upload_ops progress

    Scenario: Client reports external progress
      Given an entry is in external mode
      When the client pushes upload_progress {name: "avatar", ref: "e_001", progress: 42} on the main channel
      Then the runtime enqueues an upload_op {op: "progress", upload: "avatar", store_id: [], ref: "e_001", progress: 42}

    Scenario: Final external progress triggers completion
      When the client pushes upload_progress with progress 100 for e_001
      Then the runtime enqueues an upload_op {op: "complete", upload: "avatar", store_id: [], ref: "e_001"}
