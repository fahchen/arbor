---
id: BDR-0021
title: :timeout option for assign_async/start_async is an Arbor extension over LV
status: accepted
date: 2026-05-08
summary: LV does not provide a built-in async timeout. Arbor adds :timeout, implemented as a runtime-side timer (Process.send_after) that kills the task pid on fire and writes Arbor.AsyncResult.failed(prior, {:exit, :timeout}).
---

## Scope

**Feature**: async/features/lifecycle.feature
**Rule**: A :timeout option terminates an overdue task and produces failed: {:exit, :timeout}

## Reason

Many async workloads have a known acceptable upper bound (e.g., HTTP fetch < 5 s) beyond which the result is no longer useful. Without a built-in timeout, store authors must reimplement the same timer-and-kill dance per task, and forgetting to do so leaves slow tasks holding resources indefinitely. `Phoenix.LiveView` does not provide an async timeout option (`run_async_task` in `async.ex` uses `Task.start_link` without a timer), so applications must roll their own.

Arbor adds `:timeout` (positive integer milliseconds) to `assign_async/4` and `start_async/4`. Implementation: when a task is spawned, the runtime calls `Process.send_after(self(), {:timeout, ref}, timeout)`. On receipt, if the ref is still tracked, the runtime kills the task pid; the resulting `:DOWN` message produces `failed: {:exit, :timeout}` (or, for `start_async`, a `handle_async/3` invocation with `{:exit, :timeout}`). If the task completes naturally first, the timer is cancelled. The exit reason `:timeout` is not specially elevated to a separate AsyncResult field — it stays inside `failed: {:exit, ...}` to keep the result classification table tight (Rule 11).

A `:timeout` value of `:infinity` (or omitting the option) means no timer. Configuration ergonomics mirror the rest of the BEAM ecosystem (`GenServer.call/3` timeout, `Task.await/2` timeout).
