defmodule Musubi.Upload.CoalesceTest do
  @moduledoc """
  Direct unit coverage of progress-op coalescing inside one drain
  window. The page-server 10 Hz throttle is exercised separately by
  the simulate-driven tests; here we cover the in-socket coalescing
  step independently.
  """

  use ExUnit.Case, async: true

  alias Musubi.Socket

  test "consecutive progress ops on the same ref collapse to the latest" do
    socket = %Socket{module: nil}

    socket =
      socket
      |> Musubi.Upload.enqueue_progress(:avatar, "e_001", 10)
      |> Musubi.Upload.enqueue_progress(:avatar, "e_001", 20)
      |> Musubi.Upload.enqueue_progress(:avatar, "e_001", 30)

    assert [%{op: "progress", progress: 30, upload: "avatar", ref: "e_001"}] =
             Musubi.Upload.pending_ops(socket)
  end

  test "throttle is per-entry: two refs each keep their latest progress" do
    socket = %Socket{module: nil}

    socket =
      socket
      |> Musubi.Upload.enqueue_progress(:avatar, "e_001", 10)
      |> Musubi.Upload.enqueue_progress(:avatar, "e_002", 11)
      |> Musubi.Upload.enqueue_progress(:avatar, "e_001", 30)
      |> Musubi.Upload.enqueue_progress(:avatar, "e_002", 31)

    progress_by_ref =
      socket
      |> Musubi.Upload.pending_ops()
      |> Map.new(fn %{ref: ref, progress: p} -> {ref, p} end)

    assert progress_by_ref == %{"e_001" => 30, "e_002" => 31}
  end

  test "non-progress op flushes the coalescing run" do
    socket = %Socket{module: nil}

    socket =
      socket
      |> Musubi.Upload.enqueue_progress(:avatar, "e_001", 10)
      |> Musubi.Upload.enqueue_complete(:avatar, "e_001")
      |> Musubi.Upload.enqueue_progress(:avatar, "e_001", 20)

    ops = Musubi.Upload.pending_ops(socket)
    assert length(ops) == 3
    assert Enum.map(ops, & &1.op) == ["progress", "complete", "progress"]
  end
end
