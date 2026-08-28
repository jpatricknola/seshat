defmodule Seshat.Eval.Recorder.Stdio do
  @moduledoc """
  The stdio loop around `Seshat.Eval.Recorder`: read a line of JSON-RPC from
  stdin, hand it to the pure handler, write the reply to stdout, append any new
  trace entries to the trace file.

  Stdout carries JSON-RPC and nothing else — a stray `IO.puts` here corrupts the
  session for the client. Anything worth saying goes to stderr, the same
  arrangement `mix mcp` already relies on.

  Both directions use the **binary** IO functions on purpose. Erlang's standard
  IO device takes its encoding from the locale, and on a machine whose `LANG` is
  not a UTF-8 one it is `latin1` — measured here, an em-dash in
  `Seshat.Instructions` came out of `IO.puts` as the seven literal characters
  `\\x{2014}`, which is not JSON and not the instructions either. `IO.binwrite/2`
  and `IO.binread/2` move bytes and leave the encoding to JSON.

  The loop ends when stdin closes, which is how Claude Code shuts a stdio server
  down. One recorder process therefore serves exactly one trial by construction:
  nothing has to reset state between runs because nothing is reused.
  """

  alias Seshat.Eval.Recorder

  @doc """
  Serves one client until stdin closes, appending each call to `trace_path`.
  """
  @spec serve(Recorder.t(), Path.t()) :: :ok
  def serve(%Recorder{} = recorder, trace_path) do
    trace_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(trace_path, "")

    loop(recorder, trace_path, 0)
  end

  defp loop(recorder, trace_path, written) do
    case IO.binread(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        IO.binwrite(:stderr, "routing recorder: stdin error #{inspect(reason)}\n")
        :ok

      line ->
        {recorder, written} = handle_line(recorder, trace_path, written, String.trim(line))
        loop(recorder, trace_path, written)
    end
  end

  defp handle_line(recorder, _trace_path, written, ""), do: {recorder, written}

  defp handle_line(recorder, trace_path, written, line) do
    case Jason.decode(line) do
      {:ok, request} when is_map(request) ->
        {reply, recorder} = Recorder.handle(request, recorder)
        if reply, do: IO.binwrite(:stdio, [Jason.encode!(reply), ?\n])
        {recorder, flush_trace(recorder, trace_path, written)}

      _ ->
        # A malformed line has no id to answer against, so there is nothing to
        # reply to. Say so on stderr and keep serving.
        IO.binwrite(:stderr, "routing recorder: could not decode a line as JSON-RPC\n")
        {recorder, written}
    end
  end

  # Append-only, one JSON object per line, flushed after every request so a
  # killed trial still leaves the calls it managed to make.
  defp flush_trace(recorder, trace_path, written) do
    new = Enum.drop(recorder.trace, written)

    if new != [] do
      lines = Enum.map_join(new, "", &(Jason.encode!(&1) <> "\n"))
      File.write!(trace_path, lines, [:append])
    end

    length(recorder.trace)
  end
end
