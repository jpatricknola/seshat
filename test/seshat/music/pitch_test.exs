defmodule Seshat.Music.PitchTest do
  use ExUnit.Case, async: true

  alias Seshat.Music.Pitch

  describe "note_name/1" do
    test "middle C is C4, matching Ableton's own display" do
      assert Pitch.note_name(60) == "C4"
    end

    test "octaves go down as well as up" do
      assert Pitch.note_name(36) == "C2"
      assert Pitch.note_name(24) == "C1"
      assert Pitch.note_name(12) == "C0"
      assert Pitch.note_name(0) == "C-1"
      assert Pitch.note_name(72) == "C5"
    end

    test "names accidentals with sharps" do
      assert Pitch.note_name(61) == "C#4"
      assert Pitch.note_name(70) == "A#4"
    end

    test "names the rest of the octave" do
      assert Pitch.note_name(62) == "D4"
      assert Pitch.note_name(64) == "E4"
      assert Pitch.note_name(65) == "F4"
      assert Pitch.note_name(67) == "G4"
      assert Pitch.note_name(69) == "A4"
      assert Pitch.note_name(71) == "B4"
    end

    test "covers the ends of the MIDI range" do
      assert Pitch.note_name(127) == "G9"
    end
  end

  describe "pitch_class_name/1" do
    test "names a pitch class, C = 0" do
      assert Pitch.pitch_class_name(0) == "C"
      assert Pitch.pitch_class_name(2) == "D"
      assert Pitch.pitch_class_name(11) == "B"
    end

    test "folds a full MIDI note number into its pitch class" do
      assert Pitch.pitch_class_name(60) == "C"
      assert Pitch.pitch_class_name(61) == "C#"
    end

    test "falls back to the raw value if Live reports something unexpected" do
      assert Pitch.pitch_class_name("Chromatic") == "Chromatic"
    end
  end
end
