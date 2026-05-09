<!--
PR title: conventional commit format — type(scope): description
e.g. feat(m1): add stream/3 macro for state declarations
     fix(replication): drop move/copy/test JSON Patch ops
     refactor(dsl): collapse normalize_fields into shared helper

Since we squash merge, the title and description become the merge commit message.
Delete optional sections if empty to keep commit body clean.
-->

## Summary

<!-- What changed and why. Behavior context over implementation details. -->

## Decisions

<!-- Non-obvious technical choices and rationale. Delete if none. -->
<!--
e.g.
- typed_structor's eager opts evaluation forces Macro.escape(opts) at the field/3 wrapper
- AsyncResult.of(stream(T)) intentionally not registered as a stream slot in M1 — M5 stream_async owns that
-->

## Spec

<!-- Feature file(s) and BDR(s) this implements or amends. Delete if none. -->
<!--
e.g. spec/domains/runtime/features/render-contract.feature (Rule "stream/3 inside state do registers a stream slot")
     spec/decisions/BDR-0014-pure-minimal-diff.md
-->
