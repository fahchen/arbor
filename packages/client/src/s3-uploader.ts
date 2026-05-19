// Default S3-compatible direct-to-cloud uploader.
//
// Implements the `ExternalUploader` contract: PUTs the file body to the
// presigned `url` returned by the server's `upload_external/3` callback,
// streams progress through `xhr.upload.onprogress`, and supports abort via
// the provided `AbortSignal`.
//
// The server's `meta` payload is expected to be `{ url, headers? }`. Any
// additional fields are ignored — applications that need custom semantics
// should ship their own uploader.

import type { ExternalUploader, ExternalUploaderArgs } from "./types"

interface S3Meta {
  url: string
  headers?: Record<string, string>
}

export const S3Uploader: ExternalUploader = (args: ExternalUploaderArgs): Promise<void> => {
  const meta = args.meta as S3Meta

  if (!meta || typeof meta.url !== "string") {
    return Promise.reject(new Error("S3Uploader: meta.url is required"))
  }

  return new Promise<void>((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open("PUT", meta.url, true)

    if (meta.headers) {
      for (const [key, value] of Object.entries(meta.headers)) {
        xhr.setRequestHeader(key, value)
      }
    }

    xhr.upload.onprogress = (event: ProgressEvent) => {
      if (event.lengthComputable) {
        args.onProgress(Math.round((event.loaded / event.total) * 100))
      }
    }

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve()
      } else {
        reject(new Error(`S3Uploader: PUT failed with status ${xhr.status}`))
      }
    }

    xhr.onerror = () => reject(new Error("S3Uploader: network error"))
    xhr.onabort = () => reject(new Error("S3Uploader: aborted"))

    args.signal.addEventListener("abort", () => xhr.abort())

    xhr.send(args.file)
  })
}
