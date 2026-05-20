---
id: BDR-0026
title: Per-entry sub-channel with stateless signed-token authorization
status: accepted
date: 2026-05-19
summary: Each upload entry runs through a dedicated `musubi_upload:<entry_ref>` channel, joined with a Phoenix.Token signed during `allow_upload` preflight. `Musubi.Transport.UploadChannel` is stateless: it verifies the token, recovers store pid and per-entry limits from the token payload, and writes chunks to a `Plug.Upload.random_file/1` temp file. No server-side authorization table is kept.
---

## Scope

**Feature**: domains/uploads/features/transport.feature
**Rule**: Upload chunks travel on a dedicated sub-channel authorized by a self-contained signed token

## Reason

Three forces shape this decision:

1. **The transport already terminates at a `Phoenix.Socket`.** Adding a
   second HTTP endpoint for binary upload would duplicate session
   wiring, authentication, CORS handling, and back-pressure plumbing,
   while still requiring a separate signal path for progress and
   cancellation. Reusing the existing socket is cheaper end-to-end.

2. **Binary chunks must not block command/event traffic.** Phoenix
   Channels multiplex over a single WebSocket connection but route each
   topic to an independent process. Putting upload chunks on a
   dedicated topic (`musubi_upload:<entry_ref>`) isolates upload
   back-pressure and crash semantics from the page channel without
   opening another TCP connection. The naming mirrors LiveView's
   `lvu:*` pattern; the separate namespace ensures store-channel
   allowlists and per-topic ACLs do not conflict.

3. **`UploadChannel` should not consult shared mutable state.** The
   single page socket may carry multiple uploads, multiple stores, and
   multiple sessions; the channel process for one entry must verify
   limits (`max_file_size`, `accept`, `chunk_size`) and target (`store_pid`,
   `entry_ref`) without racing against a global authorization table or
   walking the store tree. A signed token solves this: the
   `Phoenix.Token.sign(endpoint, "musubi_upload", payload)` issued by
   the page server during `allow_upload` preflight carries every
   authority signal the channel needs:

   ```elixir
   %{
     store_pid:     pid(),
     store_id:      [String.t()],
     conf_ref:      String.t(),
     entry_ref:     String.t(),
     max_file_size: integer(),
     client_size:   integer(),
     accept:        [String.t()] | :any,
     chunk_size:    integer(),
     chunk_timeout: integer()
   }
   ```

   `store_id` is included so the sub-channel can attribute chunk
   notifications back to the correct store node without consulting any
   shared mutable table — required for the child-store dynamic pattern
   in BDR-0028.

   `client_size` lets the sub-channel detect completion on the final
   `"chunk"` frame (bytes_written ≥ client_size) without an extra
   client-side `"close"` event. `chunk_timeout` arms the per-entry
   watchdog directly on the channel process.

   The `accept` list rides in the token for completeness, but
   `accept` enforcement is **preflight-only**: the page server has
   already validated `client_name`/`client_type` before signing, and a
   live token is itself proof that those checks passed. The
   sub-channel does not re-validate per chunk (filename and MIME are
   not carried on chunk frames; carrying them would only let a buggy
   or malicious client lie a second time about a value that was
   already authorized). If an entry's accept set needs to change, the
   application should cancel the entry and re-preflight.

   The channel verifies on join (`max_age: 600`), recovers the payload,
   confirms the pid is alive, and rejects the join otherwise. Cancel is
   then mechanical: killing the channel pid invalidates the upload, and
   the dead store pid invalidates outstanding tokens.

The token never appears in render output or `upload_ops`. It is
emitted exactly once in the `allow_upload` reply for the entry. Error
messages on the upload itself are scrubbed (`{code, message}` with no
infrastructure detail) so failed verification does not leak token
internals.
