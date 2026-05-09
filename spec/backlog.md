# Backlog

## Deferred Features

(All BDD discoveries from the initial backlog have been completed. New features land here as future work surfaces.)

## Excluded From BDD Scope

- **persistence/snapshot-roundtrip** — Surfaced and explored 2026-05-09. Decision: persistence is **not** an Arbor primitive. Applications implement snapshot save/load via the existing hook (`attach_hook(socket, :persist, :after_command, fn)`) and extension points. Arbor exposes no `Arbor.Persistence` behaviour, no bundled ETS/Postgres adapters, no `persist_now/1` helper, no `persist: :ok_only` opt-in. The pattern may be packaged as a separate companion library (`Arbor.Persistence`) outside the core runtime. Documentation of recommended hook usage lives in `docs/persistence-pattern.md` (TBD).

## Open Decisions

(None at present.)
