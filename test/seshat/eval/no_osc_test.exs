defmodule Seshat.Eval.NoOSCTest do
  @moduledoc """
  The routing eval must never touch Ableton.

  Not a style preference. Only one process can bind AbletonOSC's reply port, so
  an eval that opened a socket would either be deaf or would take the port from
  the Seshat the user is actually working in — and a harness that mutated a real
  Set while measuring which tool a model picks would destroy the thing it is
  measuring. The whole design (surface snapshots, a fixture, a record-only
  server) exists to make that impossible; this grep is what keeps it impossible
  after somebody reaches for "just one real read".

  Same shape as `Seshat.AX.ClientTest`'s process-start grep.
  """

  use ExUnit.Case, async: true

  @forbidden ~r/Transport|\/live\/|:gen_udp|Session\.State/

  test "nothing in the eval tree reaches OSC" do
    files =
      Path.wildcard("lib/seshat/eval/**/*.ex") ++
        Path.wildcard("lib/mix/tasks/routing.*.ex") ++
        Path.wildcard("priv/routing_eval/bin/*")

    assert files != [], "the grep found no files to check — the paths moved"

    offenders = Enum.filter(files, &(File.read!(&1) =~ @forbidden))

    assert offenders == [],
           """
           These routing-eval files mention OSC:

           #{Enum.join(offenders, "\n")}

           The eval serves a frozen surface snapshot and a fixture. It must not
           open a socket, read the live mirror, or name a `/live/` address:
           only one process can hold AbletonOSC's reply port, and a routing
           measurement that mutates a real Set is not a measurement.
           """
  end

  test "the recorder wrapper launches the recorder task and nothing else" do
    body = File.read!("priv/routing_eval/bin/recorder")

    assert body =~ "mix routing.recorder"
    refute body =~ "app.start"
    refute body =~ "phx.server"
  end
end
