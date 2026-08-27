defmodule Seshat.Tools.NoteEditTest do
  @moduledoc """
  The arithmetic behind `edit_notes`, tested without a transport.

  `Seshat.Tools.Handlers` owns the OSC — the guards, the read, the remove/add
  pair, the read-back. What each matched note *becomes*, and whether the request
  is coherent at all, is here, which is why these cases need no sink: a refusal
  that reaches the wire is a bug the handler tests catch, and a refusal's
  wording is what the model actually acts on.
  """

  use ExUnit.Case, async: true

  alias Seshat.Tools.NoteEdit

  defp note(overrides \\ %{}) do
    Map.merge(
      %{pitch: 60, start_time: 0.0, duration: 1.0, velocity: 100.0, mute: false},
      overrides
    )
  end

  describe "changes/1" do
    test "keeps only the change keys, dropping the window and the indices" do
      params = %{
        "track" => 0,
        "clip_slot" => 1,
        "start_pitch" => 60,
        "pitch_span" => 1,
        "transpose" => 12,
        "delete" => false
      }

      assert NoteEdit.changes(params) == %{"transpose" => 12, "delete" => false}
    end
  end

  describe "validate/1" do
    test "no change at all names every change the tool understands" do
      assert {:error, message} = NoteEdit.validate(%{})

      assert message =~ "transpose"
      assert message =~ "velocity_delta"
      assert message =~ "delete: true"
      assert message =~ "Nothing was changed"
    end

    test "absolute and relative velocity together is a contradiction, not a merge" do
      assert {:error, message} =
               NoteEdit.validate(%{"velocity" => 80, "velocity_delta" => 10})

      assert message =~ "same field two different ways"
    end

    test "delete cannot be combined with an edit, and the message names the edit" do
      assert {:error, message} = NoteEdit.validate(%{"delete" => true, "transpose" => 12})

      assert message =~ "transpose"
      assert message =~ "separate calls"
    end

    test "delete: false alone asks for nothing" do
      assert {:error, message} = NoteEdit.validate(%{"delete" => false})
      assert message =~ "delete: true"
    end

    test "delete: true alone is the whole point, and passes" do
      assert :ok = NoteEdit.validate(%{"delete" => true})
    end

    test "one edit is enough" do
      assert :ok = NoteEdit.validate(%{"shift" => -0.5})
    end
  end

  describe "delete?/1" do
    test "only a truthy delete counts" do
      assert NoteEdit.delete?(%{"delete" => true})
      assert NoteEdit.delete?(%{"delete" => 1})
      refute NoteEdit.delete?(%{"delete" => false})
      refute NoteEdit.delete?(%{"transpose" => 12})
    end
  end

  describe "apply/2" do
    test "transpose moves the pitch and leaves everything else alone" do
      assert {:ok, [edited], 0} = NoteEdit.apply([note()], %{"transpose" => -12})

      assert edited.pitch == 48
      assert edited.start_time == 0.0
      assert edited.duration == 1.0
      assert edited.velocity == 100
    end

    # The reply carries velocity as a float and mute as a boolean; the wire
    # wants an integer and 0|1. Rounding here is what makes the note re-sendable
    # at all.
    test "velocity comes back as an integer even when nothing asked it to" do
      assert {:ok, [edited], 0} =
               NoteEdit.apply([note(%{velocity: 99.6})], %{"transpose" => 0})

      assert edited.velocity === 100
    end

    test "an absolute velocity replaces every matched note's own" do
      notes = [note(%{velocity: 37.0}), note(%{pitch: 62, velocity: 127.0})]

      assert {:ok, edited, 0} = NoteEdit.apply(notes, %{"velocity" => 64})
      assert Enum.map(edited, & &1.velocity) == [64, 64]
    end

    # Clamping is the musical intent of "make it all a bit louder" — the one
    # place `edit_notes` clamps rather than refuses.
    test "velocity_delta adds, clamps at both ends, and counts what it clamped" do
      notes = [note(%{velocity: 120.0}), note(%{velocity: 100.0}), note(%{velocity: 5.0})]

      assert {:ok, edited, 1} = NoteEdit.apply(notes, %{"velocity_delta" => 20})
      assert Enum.map(edited, & &1.velocity) == [127, 120, 25]

      assert {:ok, edited, 1} = NoteEdit.apply(notes, %{"velocity_delta" => -10})
      assert Enum.map(edited, & &1.velocity) == [110, 90, 1]
    end

    test "duration is absolute, shift is relative" do
      notes = [note(%{start_time: 1.0, duration: 0.25})]

      assert {:ok, [by_duration], 0} = NoteEdit.apply(notes, %{"duration" => 2.0})
      assert by_duration.duration == 2.0
      assert by_duration.start_time == 1.0

      assert {:ok, [by_shift], 0} = NoteEdit.apply(notes, %{"shift" => -0.5})
      assert by_shift.start_time == 0.5
      assert by_shift.duration == 0.25
    end

    test "mute survives an edit" do
      assert {:ok, [edited], 0} =
               NoteEdit.apply([note(%{mute: true})], %{"velocity_delta" => 1})

      assert edited.mute == true
    end

    # Clamping pitch would silently pile a transposed chord onto G9; refusing
    # costs one retry with a smaller interval, and the message says which.
    test "a transpose above 127 refuses the whole call, naming the count and the ceiling" do
      notes = [note(%{pitch: 120}), note(%{pitch: 60}), note(%{pitch: 127})]

      assert {:error, message} = NoteEdit.apply(notes, %{"transpose" => 12})

      assert message =~ "2 notes"
      assert message =~ "nothing was changed"
      assert message =~ "smaller interval"
    end

    test "a transpose below 0 refuses the same way" do
      assert {:error, message} = NoteEdit.apply([note(%{pitch: 3})], %{"transpose" => -12})

      assert message =~ "1 note"
      assert message =~ "below"
    end

    test "a shift that would start a note before beat 0 refuses" do
      notes = [note(%{start_time: 0.25}), note(%{start_time: 4.0})]

      assert {:error, message} = NoteEdit.apply(notes, %{"shift" => -1.0})

      assert message =~ "1 note"
      assert message =~ "beat 0"
      assert message =~ "nothing was changed"
    end

    test "the exact bounds are legal, not off by one" do
      assert {:ok, [top], 0} = NoteEdit.apply([note(%{pitch: 115})], %{"transpose" => 12})
      assert top.pitch == 127

      assert {:ok, [bottom], 0} = NoteEdit.apply([note(%{pitch: 12})], %{"transpose" => -12})
      assert bottom.pitch == 0

      assert {:ok, [at_zero], 0} = NoteEdit.apply([note(%{start_time: 1.0})], %{"shift" => -1.0})
      assert at_zero.start_time == 0.0
    end

    test "the edited notes come back in the input order" do
      notes = [note(%{pitch: 67}), note(%{pitch: 60}), note(%{pitch: 64})]

      assert {:ok, edited, 0} = NoteEdit.apply(notes, %{"transpose" => 1})
      assert Enum.map(edited, & &1.pitch) == [68, 61, 65]
    end
  end
end
