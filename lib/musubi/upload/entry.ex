defmodule Musubi.Upload.Entry do
  @moduledoc """
  One client-selected file currently tracked by the runtime.

  ## Wire whitelist

  Only the public fields are serialized to the client (`@derive
  {Musubi.Wire, only: [...]}`); server-private fields stay on the BEAM
  for runtime bookkeeping. The whitelist is the single source of truth
  for what an entry's `entry: %{...}` payload looks like in `upload_ops`.

  Public fields:

    * `:ref` — server-issued entry id (binary).
    * `:client_name` — original filename as reported by the client.
    * `:client_size` — file size reported by the client (bytes).
    * `:client_type` — MIME type as reported by the client.
    * `:progress` — 0..100 integer.
    * `:status` — see `t:status/0`.
    * `:errors` — list of `Musubi.Upload.Error.t()`.

  Private fields:

    * `:path` — temp file path (channel mode only).
    * `:token` — Phoenix.Token issued for this entry; never serialized.
    * `:store_pid` — owning store page server pid.
    * `:upload_channel_pid` — sub-channel pid once joined.
    * `:bytes_written` — accumulated bytes received so far (channel mode).
    * `:external_meta` — opaque map from `upload_external/3` (external mode).
    * `:preflighted_at` — monotonic time the entry passed preflight.
    * `:mode` — `:channel` or `:external`.
  """

  use TypedStructor

  alias Musubi.Upload.Error

  @derive {Musubi.Wire,
           only: [:ref, :client_name, :client_size, :client_type, :progress, :status, :errors]}

  @type status() :: :pending | :uploading | :success | :error | :cancelled
  @type mode() :: :channel | :external

  typed_structor do
    field :ref, String.t(), enforce: true, doc: "Server-issued entry ref."
    field :client_name, String.t(), enforce: true, doc: "Filename as reported by the client."
    field :client_size, non_neg_integer(), enforce: true, doc: "Size as reported by the client."
    field :client_type, String.t(), default: "", doc: "MIME type as reported by the client."
    field :progress, non_neg_integer(), default: 0, doc: "Server-confirmed progress 0..100."
    field :status, status(), default: :pending, doc: "Entry lifecycle status."
    field :errors, [Error.t()], default: [], doc: "Per-entry errors."

    field :mode, mode(), default: :channel, doc: "Entry mode — :channel or :external."
    field :path, String.t() | nil, default: nil, doc: "Temp file path (channel mode)."

    field :token, String.t() | nil,
      default: nil,
      doc: "Issued Phoenix.Token. Never serialized."

    field :store_pid, pid() | nil, default: nil, doc: "Owning page server pid."

    field :upload_channel_pid, pid() | nil, default: nil, doc: "Sub-channel pid when joined."

    field :bytes_written, non_neg_integer(), default: 0, doc: "Bytes received (channel mode)."
    field :external_meta, map() | nil, default: nil, doc: "External-mode opaque meta."

    field :preflighted_at, integer() | nil, default: nil, doc: "Monotonic time of preflight."
  end
end
