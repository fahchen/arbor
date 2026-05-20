@uploads @transport
Feature: Upload Transport
  As a runtime
  I want preflight to authorize each entry with a self-contained signed token
  So that per-entry chunk channels can verify limits and target store without consulting any shared mutable table

  Background:
    Given a connected client
    And a page runtime with an upload :avatar declared with accept ~w(.png), max_entries 1, max_file_size 5_000_000, chunk_size 64_000

  Rule: allow_upload preflight signs a token per accepted entry

    Scenario: Single valid entry
      When the client sends allow_upload with one entry {client_ref: "0", name: "me.png", size: 12345, type: "image/png"}
      Then the server replies with %{ref: _, config: %{chunk_size: 64_000, max_file_size: 5_000_000, max_entries: 1}, entries: %{"0" => %{type: "channel", entry_ref: _, token: _}}, errors: []}
      And the token verifies as a Phoenix.Token signed under the "musubi_upload" salt with max_age 600
      And the token payload contains store_pid, conf_ref, entry_ref, max_file_size, accept, and chunk_size
      And the runtime emits an upload_op {op: "add", upload: "avatar", store_id: [], ref: entry_ref, entry: %{...}}

    Scenario: Preflight rejects too-large entry
      When the client sends allow_upload with an entry of size 10_000_000
      Then the server replies with the entry under errors with code "too_large"
      And no token is signed for that entry
      And no upload_op {op: "add"} is emitted for that entry

    Scenario: Preflight rejects unacceptable extension
      When the client sends allow_upload with an entry name "me.gif" of type "image/gif"
      Then the server replies with the entry under errors with code "not_accepted"
      And no token is signed for that entry

    Scenario: Preflight rejects when entries exceed max_entries
      Given max_entries is 1
      And one entry is already accepted for avatar
      When the client sends allow_upload with another entry
      Then the server replies with errors carrying code "too_many_files"

  Rule: The per-entry sub-channel uses topic musubi_upload:<entry_ref> and joins with the signed token

    Scenario: Join with a valid token
      Given the client has a valid token for entry_ref e_001
      When the client joins channel "musubi_upload:e_001" with payload %{token: token}
      Then the join succeeds
      And the server opens a Plug.Upload temp file for the channel

    Scenario: Join with an unrecognized topic format
      When the client joins channel "musubi_upload:not_a_real_ref" with any token
      Then the join is rejected

    Scenario: Join with a forged or expired token
      When the client joins channel "musubi_upload:e_001" with payload %{token: "expired-or-forged"}
      Then the join is rejected
      And no temp file is opened

    Scenario: Join after the owning store pid has died
      Given the page runtime has terminated
      When the client attempts to join "musubi_upload:e_001" with the previously valid token
      Then the join is rejected

  Rule: UploadChannel is stateless — limits and target come from the token alone

    Scenario: Token carries max_file_size
      Given the token for e_001 was signed with max_file_size 5_000_000
      When the client pushes a "chunk" carrying 64_000 bytes 79 times for a total of 5_056_000 bytes
      Then the channel rejects further chunks with an "upload too large" error and emits {op: "error", code: "too_large"}

    Scenario: Token carries chunk_size enforced at the channel
      Given the token for e_001 was signed with chunk_size 64_000
      When the client pushes a "chunk" of 80_000 bytes
      Then the channel rejects the chunk with a "chunk too large" error

  Rule: chunk events carry a raw binary frame

    Scenario: Server writes chunk to the temp file and emits a progress op
      Given the client has joined "musubi_upload:e_001"
      When the client pushes "chunk" with a 64_000-byte ArrayBuffer
      Then the server writes the bytes to the entry's temp file
      And the server enqueues an upload_op {op: "progress", upload: "avatar", store_id: [], ref: "e_001", progress: N}
      And the channel replies with %{progress: N}

  Rule: cancel_upload tears down the sub-channel and cleans the temp file

    Scenario: Client cancels an in-progress entry
      Given an in-progress upload entry e_001
      When the client sends cancel_upload {name: "avatar", ref: "e_001"} on the main channel
      Then the UploadChannel pid is terminated
      And the temp file for e_001 is removed
      And the runtime emits {op: "cancel", upload: "avatar", store_id: [], ref: "e_001"}

  Rule: Sub-channel termination cleans up

    Scenario: Client disconnects mid-upload
      Given an in-progress upload entry e_001 on a sub-channel
      When the client's transport disconnects
      Then the UploadChannel terminates
      And the temp file is removed
      And on reconnect the upload state begins empty (no add op for e_001)
