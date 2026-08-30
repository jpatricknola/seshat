# Attribution — style_profiles.json

`style_profiles.json` carries per-style drum-feel statistics: mean and spread of
onset timing per lane, velocity by accent class, ghost density, swing. Six of
the eleven profiles (`rock`, `funk`, `jazz`, `latin`, `hiphop`, `dance`) are
**derived from the Groove MIDI Dataset**; the other five (`lofi`, `boom_bap`,
`house`, `techno`, `trap`) are **authored** from those, each naming its donor in
`authored_from` and its adjustments in `authored_note`.

## Source

**Groove MIDI Dataset (GMD) v1.0.0**

> Jon Gillick, Adam Roberts, Jesse Engel, Douglas Eck, David Bamman.
> "Learning to Groove with Inverse Sequence Transformations."
> *International Conference on Machine Learning (ICML)*, 2019.

<https://magenta.tensorflow.org/datasets/groove>

Licensed **CC-BY 4.0** (<https://creativecommons.org/licenses/by/4.0/>).

## What is and is not distributed

Nothing from the dataset ships with Seshat. `experiments/gmd_profiles/harvest.py`
downloads the archive at development time, reads it, and writes summary
statistics — means, standard deviations, medians and percentiles taken across
hundreds of performances. No MIDI file, no phrase and no per-performance data is
copied into `style_profiles.json`, and nothing in `lib/` reads the dataset at
run time. CC-BY 4.0 permits redistribution of the dataset itself with
attribution; this arrangement stays well inside that, and the attribution above
is given regardless.

## Rebuilding

```
python3 experiments/gmd_profiles/harvest.py \
    --zip /path/to/groove-v1.0.0-midionly.zip \
    --out priv/midi_generation/style_profiles.json
```

The archive is downloaded to `--zip` if it is not already there, and its
SHA-256 is checked against the one recorded in the script. Commit the JSON the
run produces; `test/seshat/generation/midi/profiles_test.exs` pins every profile
inside the measured envelope, so a re-harvest that drifts fails the suite rather
than shipping quietly.
