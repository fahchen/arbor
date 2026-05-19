@uploads @external
Feature: Upload External Mode
  As a store author
  I want to opt an upload into direct-to-cloud delivery via `upload_external/3`
  So that bytes never traverse the BEAM and progress still flows through Musubi (BDR-0027)

  Background:
    Given a connected client
    And a page runtime with an upload :avatar declared on a store
    And a registered client uploader named "S3"

  Rule: Defining `upload_external/3` switches the preflight reply to external entries

    Scenario: Implemented for the upload name
      Given the store implements upload_external(:avatar, entry, socket) returning {:ok, %{uploader: "S3", url: "https://example/u", headers: %{}}, socket}
      When the client sends allow_upload for one entry
      Then the preflight reply carries %{type: "external", entry_ref: _, uploader: "S3", meta: %{"url" => "https://example/u", "headers" => %{}}}
      And no Phoenix.Token is signed for that entry
      And the runtime emits an upload_op {op: "add", upload: "avatar", store_id: [], ref: entry_ref, entry: %{...}}

    Scenario: Per-name fallback to channel mode
      Given the store implements upload_external(:cover, entry, socket) but does not define a matching clause for :avatar
      When the client sends allow_upload for :avatar
      Then the preflight reply carries %{type: "channel", entry_ref: _, token: _} for that entry
      And no upload_external/3 dispatch is observed for :avatar

    Scenario: Explicit channel fallback per entry
      Given the store implements upload_external(:avatar, _, socket) returning :channel
      When the client sends allow_upload for :avatar
      Then the preflight reply carries %{type: "channel", entry_ref: _, token: _} for that entry

    Scenario: Socket mutations in upload_external/3 survive
      Given the store implements upload_external/3 that assigns :last_meta on the socket
      When the client sends allow_upload for :avatar
      Then the page server's socket assigns reflect :last_meta after preflight

  Rule: Progress flows through `upload_progress` on the main channel

    Scenario: Client reports external progress
      Given an external entry e_001 has been accepted
      When the client pushes upload_progress {name: "avatar", ref: "e_001", progress: 42} on the main channel
      Then the runtime enqueues upload_op {op: "progress", upload: "avatar", store_id: [], ref: "e_001", progress: 42}

    Scenario: Final external progress triggers completion
      When the client pushes upload_progress with progress 100 for e_001
      Then the runtime enqueues upload_op {op: "complete", upload: "avatar", store_id: [], ref: "e_001"}

    Scenario: Channel-mode entry rejects forged upload_progress
      Given an entry e_002 is in channel mode
      When the client pushes upload_progress for e_002 on the main channel
      Then the server replies with %{reason: "wrong mode"} and emits no progress op for e_002

  Rule: External uploader failures surface as scrubbed error ops

    Scenario: Registered uploader rejects the PUT
      Given an external entry e_001 has been accepted
      And the registered S3 uploader rejects the PUT with a 500
      When the client reports the failure via upload_progress with a negative progress (or omits to reach 100)
      Then the runtime can emit upload_op {op: "error", upload: "avatar", ref: "e_001", error: %{code: "external_failed", message: _}}
      And the error message contains no infrastructure detail

    Scenario: Missing uploader registration on the client
      Given the registered uploader map does not include "S3"
      When the client attempts to start the upload
      Then the client surfaces an UploadError with code "external_failed"
      And the server retains the entry until the client cancels or resets

  Rule: External entries can be cancelled

    Scenario: Client cancels an in-flight external entry
      Given an external entry e_001 is uploading
      When the client sends cancel_upload {name: "avatar", ref: "e_001"} on the main channel
      Then the runtime emits {op: "cancel", upload: "avatar", store_id: [], ref: "e_001"}
      And the entry is removed from the index
