defmodule Seshat.Generation.Midi.Performance do
  @moduledoc """
  The performance layer: gridded onsets in, eight-field Live notes out.

  This is where the 2026-08-25 failure is answered. A model asked for notes one
  map at a time produces uniform velocities on an exact grid, because that is
  what a note map is; it knows perfectly well what a lazy backbeat is and has no
  way to say so. So the model writes *what* is played
  (`Seshat.Generation.Midi.Pattern`) and this writes *how*, from the committed
  style profiles: microtiming, velocity contour and spread, ghost dynamics,
  swing, and Live's own per-note `probability` and `velocity_deviation`.

  ## Deterministic, and it names its seed

  The RNG is `:rand.seed_s(:exsss, {seed, part_index, 0})`, threaded functionally
  through the fold rather than left in the process dictionary: the same request
  with the same seed produces byte-identical notes, and two parts of one request
  do not share a stream (so adding a hat part cannot change the kick's feel).
  The workflow draws a seed when the caller omits one and reports it, which is
  the whole mechanism behind "another take" and "no, the one before".

  ## `humanize: 0.0` is the raw grid, exactly

  Not "nearly": no displacement, no jitter, no velocity contour, no
  `velocity_deviation`, and `probability` 1.0 on every note including ghosts.
  That arm exists so a listener can A/B the performance layer against the grid
  it was applied to, which is the acceptance test's whole design — an arm that
  was only *mostly* mechanical would not settle anything.

  ## Units

  Profile timing numbers are signed fractions of a **16th note**, which is a
  quarter of a beat in Live at every time signature (a beat is a quarter note
  there, whatever the denominator says). `swing` is in the same units and is
  applied to off-8ths only — positions sitting exactly half a beat into a beat.
  `timing_mean` is already corrected for GMD's own capture-chain rush (every
  lane in the raw harvest skews early by the same few percent of a 16th,
  independent of any drummer) — see `harvest.py`'s `style_profile`/
  `lane_profile` — so the number here is one lane's push or drag *relative to
  the style's own average onset*, not relative to a grid GMD never measured
  directly.
  """

  # A 16th note in beats. Fixed, not derived from the time signature: Live
  # counts a beat as a quarter note regardless of the denominator.
  @sixteenth 0.25

  # Notes never land on top of one another and never reorder, so a displaced
  # onset is nudged to at least this far after its predecessor. Well under a
  # 1/128 at any sane tempo — inaudible, and enough that Live sees two notes.
  @min_gap 0.002

  # Live's own field range. `velocity_deviation` is a *spread*, so a profile's
  # raw standard deviation would be a wide one; this is the ceiling past which
  # the extra spread stops meaning anything musical.
  @max_velocity_deviation 48.0

  @default_release_velocity 64.0

  @doc """
  Perform one part's onsets.

  `onsets` come from `Seshat.Generation.Midi.Pattern.compile/4` (or from
  `Seshat.Generation.Midi.Bass`, which adds `:pitch` and `:duration` of its own).
  Each carries `:beat`, `:accent` and `:step_beats`.

  `context` carries:

    * `:pitch` — the part's MIDI pitch, used for any onset without its own
    * `:lane` — the lane profile from `Seshat.Generation.Midi.Profiles`
    * `:humanize` — 0.0–1.0, scaling every displacement and spread
    * `:swing` — signed fraction of a 16th applied to off-8ths
    * `:seed`, `:part_index` — the deterministic stream
    * `:clip_beats` — the clip's length, which no note may reach

  Returns the notes in ascending start order, each a map with exactly the eight
  fields `/live/clip/add/notes_extended` takes.
  """
  @spec perform([map()], map()) :: [map()]
  def perform(onsets, context) do
    humanize = clamp(context.humanize * 1.0, 0.0, 1.0)
    rng = :rand.seed_s(:exsss, {context.seed, context.part_index, 0})

    {notes, _rng, _previous} =
      onsets
      |> Enum.sort_by(& &1.beat)
      |> Enum.reduce({[], rng, -1.0}, fn onset, {acc, rng, previous} ->
        {note, rng} = note(onset, context, humanize, rng, previous)
        {[note | acc], rng, note.start_time}
      end)

    Enum.reverse(notes)
  end

  defp note(onset, context, humanize, rng, previous) do
    lane = context.lane
    class = class_name(onset.accent)
    velocity_spec = lane["velocity"][class]

    {timing_jitter, rng} = normal(rng, lane["timing_sd"] * 1.0)
    {velocity_jitter, rng} = normal(rng, velocity_spec["sd"] * 1.0)

    displacement =
      (lane["timing_mean"] * 1.0 + swing_for(onset.beat, context.swing) + timing_jitter) *
        humanize * @sixteenth

    start =
      (onset.beat + displacement)
      |> clamp(0.0, max(context.clip_beats - @min_gap, 0.0))
      |> then(&max(&1, previous + @min_gap))
      |> min(max(context.clip_beats - @min_gap, 0.0))

    velocity =
      (velocity_spec["mean"] * 1.0 +
         (contour(onset, context) + velocity_jitter) * humanize)
      |> keep_class_order(onset.accent, lane)
      |> clamp(1.0, 127.0)

    duration =
      Map.get(onset, :duration, onset.step_beats * 0.9)
      |> min(max(context.clip_beats - start, @min_gap))

    note = %{
      pitch: Map.get(onset, :pitch, context.pitch),
      start_time: round_beat(start),
      duration: round_beat(duration),
      velocity: Float.round(velocity, 1),
      mute: 0,
      probability: probability(onset.accent, lane, humanize),
      velocity_deviation: velocity_deviation(lane, onset.accent, velocity, humanize),
      release_velocity: @default_release_velocity
    }

    {note, rng}
  end

  # The accent classes are the model's musical instruction, and jitter shades
  # them rather than swapping them.
  #
  # It has to be said explicitly because the harvested spreads overlap: the
  # bottom velocity tercile of a whole corpus is wide, so a ghost's own spread
  # reaches well into the hit class's and vice versa. Left alone, a note the
  # model wrote as `g` could come out louder than the `x` beside it — which a
  # listener hears as a mistake, not as feel. So each class keeps a band, bounded
  # by the midpoints between the class means, and jitters freely inside it.
  defp keep_class_order(velocity, accent, lane) do
    means = lane["velocity"]
    low = (means["ghost"]["mean"] + means["hit"]["mean"]) / 2
    high = (means["hit"]["mean"] + means["accent"]["mean"]) / 2

    case accent do
      :ghost -> min(velocity, low)
      :hit -> velocity |> max(low) |> min(high)
      :accent -> max(velocity, high)
    end
  end

  # A ghost that Live re-rolls on every pass is what stops a 16-bar hat lane
  # sounding like a machine — and it is exactly what the extended-notes address
  # exists to carry. At `humanize: 0.0` it goes away with everything else.
  defp probability(:ghost, lane, humanize) when humanize > 0.0 do
    lane["ghost_probability"] |> clamp(0.05, 1.0) |> Float.round(3)
  end

  defp probability(_accent, _lane, _humanize), do: 1.0

  defp velocity_deviation(_lane, _accent, _velocity, +0.0), do: 0.0

  defp velocity_deviation(lane, accent, velocity, humanize) do
    (lane["velocity_sd"] * 1.0 * humanize)
    |> clamp(0.0, min(@max_velocity_deviation, class_room(lane, accent, velocity)))
    |> Float.round(1)
  end

  # `velocity_deviation` tells Live to re-roll the *played* velocity at up to
  # this much above what was written (`API.md`'s own wording), which is
  # exactly the band `keep_class_order/3` drew when writing the base velocity
  # in the first place — a ghost written at 50 with an unbounded 30-point
  # deviation could play as loud as 80, inside the `hit` class it was written
  # to sit under. This caps the roll so it cannot cross into a neighbouring
  # class's territory, or past Live's own velocity ceiling.
  defp class_room(lane, accent, velocity) do
    means = lane["velocity"]
    low = (means["ghost"]["mean"] + means["hit"]["mean"]) / 2
    high = (means["hit"]["mean"] + means["accent"]["mean"]) / 2

    ceiling =
      case accent do
        :ghost -> low
        :hit -> high
        :accent -> 127.0
      end

    max(ceiling - velocity, 0.0)
  end

  # The shape a drummer plays *over* the pattern rather than in it: the bar's
  # downbeat leans in, the off-16ths lean back. Small numbers on purpose — the
  # accent classes the model wrote (`X`, `x`, `g`) carry the musical decision,
  # and this only stops every `x` in a bar from being the same number.
  defp contour(onset, context) do
    beats_per_bar = context.beats_per_bar * 1.0
    position = fmod(onset.beat, beats_per_bar)

    cond do
      position < 1.0e-9 -> 6.0
      on_beat?(position) -> 2.0
      off_eighth?(onset.beat) -> -1.0
      true -> -4.0
    end
  end

  defp on_beat?(position), do: abs(position - Float.round(position)) < 1.0e-9

  defp swing_for(beat, swing) do
    if off_eighth?(beat), do: swing * 1.0, else: 0.0
  end

  # The "and" of a beat: exactly half a beat in. A 16th or a triplet sitting
  # elsewhere is not an off-8th and gets no swing displacement.
  defp off_eighth?(beat), do: abs(fmod(beat, 1.0) - 0.5) < 1.0e-9

  defp class_name(:accent), do: "accent"
  defp class_name(:hit), do: "hit"
  defp class_name(:ghost), do: "ghost"

  # Box–Muller off `:rand.uniform_s/1`, so the whole stream stays inside the
  # threaded state. `:rand.normal_s/3` would do it in one call, but the
  # functional form of the seeded stream is the point: same seed, same notes.
  defp normal(rng, +0.0), do: {0.0, rng}

  defp normal(rng, sigma) do
    {u1, rng} = :rand.uniform_s(rng)
    {u2, rng} = :rand.uniform_s(rng)
    z = :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
    # Three sigma is the tail: past that a "human" onset is a mistake, and one
    # note landing a whole 16th late is what a listener hears as broken.
    {clamp(z, -3.0, 3.0) * sigma, rng}
  end

  defp fmod(value, modulus) do
    value - modulus * Float.floor(value / modulus)
  end

  # Live stores note positions as 32-bit floats, so more than this is noise —
  # and a rounded value keeps the read-back comparison and the tests legible.
  defp round_beat(value), do: Float.round(value * 1.0, 6)

  defp clamp(value, low, high), do: value |> max(low) |> min(high)
end
