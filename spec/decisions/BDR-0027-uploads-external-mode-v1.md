---
id: BDR-0027
title: External (direct-to-cloud) upload mode ships in v1
status: accepted
date: 2026-05-19
summary: When a store implements `upload_external/3` for an upload name, the preflight reply carries `{type: "external", uploader, meta}` instead of a Musubi-side token. The client dispatches to a registered uploader that does the direct PUT to the cloud (e.g. S3, R2). Progress flows back over the main channel via `upload_progress` events, driving the same `{op: progress}` emission as channel mode.
---

## Scope

**Feature**: domains/uploads/features/external.feature
**Rule**: External mode is an alternative preflight outcome that bypasses the chunk sub-channel

## Reason

A non-trivial share of expected upload use cases are large media files
(images, audio, video) sized in tens or hundreds of megabytes, and most
production deployments already terminate that media on cloud object
storage. Forcing every byte through the application BEAM doubles
bandwidth, blocks Phoenix process memory, and slows uploads against a
backbone-to-S3 baseline. LiveView ships a direct-to-cloud uploader for
this reason. Shipping the same capability in v1 prevents the v1 API
from quickly looking incomplete next to LV in real deployments and
avoids forcing applications to choose between Musubi and direct cloud
upload.

The shape is intentionally minimal: a single new optional callback on
the store, a parallel preflight reply variant, and a client-side
uploader registry. No new wire vocabulary beyond a second entry-type
discriminator.

### Server surface

```elixir
@callback upload_external(name :: atom(), entry :: Entry.t(), Socket.t()) ::
            {:ok, meta :: map(), Socket.t()}
```

When implemented for the upload name, preflight calls it per entry to
produce an opaque `meta` map (the contract between the application and
the client uploader). Musubi forwards `meta` to the client unchanged.

### Wire shape

```json
{
  "entries": {
    "0": {"type": "channel",  "entry_ref": "e_001", "token": "SFMyNTY..."},
    "1": {"type": "external", "entry_ref": "e_002", "uploader": "S3",
          "meta": {"url": "https://...", "headers": {}}}
  }
}
```

Channel and external entries may coexist within a single preflight
response. The client dispatches to either the built-in chunk uploader
or the registered named uploader.

### Client surface

```ts
import { connect } from "@musubi/client"
import { S3Uploader } from "./uploaders/s3"  // application-owned

const connection = await connect<Musubi.Stores>(socket, {
  uploaders: { S3: S3Uploader }
})
```

`@musubi/client` exports the `ExternalUploader` contract but no
implementation — applications own the upload mechanism so the library
takes no opinion on `fetch` vs. `XMLHttpRequest`, progress
granularity, or cloud-specific quirks. Uploaders implement:

```ts
type ExternalUploader = (args: {
  entry: UploadEntry
  file: File
  meta: unknown
  onProgress: (pct: number) => void
  signal: AbortSignal
}) => Promise<void>
```

`onProgress` pushes `upload_progress` events on the main channel; the
server emits `{op: progress}` for parity with channel mode. On
completion, the client emits a final `upload_progress` with `progress:
100` and the server emits `{op: complete}`.

### Trade-off

The external path skips the per-entry sub-channel and signed-token
authorization, since the cloud uploader holds the only writable URL.
The application is responsible for keeping its presigning short-lived
and scoping the URL tightly. Musubi's contract is only that the
returned `meta` is forwarded to the named uploader and the resulting
progress is reflected back to the application's `handle_progress/3`
callback.

### Out of v1

- Custom uploader interop beyond the documented contract (e.g.
  pause/resume) — application uploaders are responsible for advanced
  semantics.
- Server-side post-upload verification (HEAD on the object, signature
  check) — left to application code in the command that consumes the
  entry.
