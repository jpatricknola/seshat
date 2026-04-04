defmodule Seshat.Commands.Parser do
  @moduledoc """
  Parses natural language input into a Command struct using the Claude API.
  """

  alias Seshat.Commands.Command
  require Logger

  @valid_commands ~w(pan volume mute solo create_track)

  @system_prompt """
  You are an Ableton Live controller. Parse the user's natural language input into a JSON command.

  For mixer commands, return:
  {"command": "<command>", "track": <integer>, "value": <number>}

  For creating a new track, return:
  {"command": "create_track", "track_type": "midi" or "audio", "name": "<instrument/purpose>"}

  Rules:
  - command: one of "pan", "volume", "mute", "solo", "create_track"
  - For pan/volume/mute/solo:
    - track: 0-indexed integer. "track 1" = 0, "track 2" = 1, etc.
    - value:
      - pan: -1.0 (full left) to 1.0 (full right). "left" = -1.0, "center" = 0.0, "right" = 1.0
      - volume: 0.0 to 1.0. "full"/"max" = 1.0, "half" = 0.5, "off"/"silent" = 0.0
      - mute: 1 (muted) or 0 (unmuted)
      - solo: 1 (on) or 0 (off)
  - For create_track:
    - track_type: "midi" for software instruments (synths, samplers, drum machines, keys, pads) or "audio" for recording external sources (vocals, guitar, bass guitar, field recordings, samples)
    - name: a short, descriptive label for the track (e.g. "Drums", "Lead Synth", "Vocals")

  If the input is ambiguous or cannot be parsed, return:
  {"error": "<brief reason>"}

  Never ask for clarification. Never return anything other than a JSON object. No explanation, no markdown.
  """

  @spec parse(String.t(), list(), list()) :: {:ok, Command.t()} | {:error, String.t()}
  def parse(input, tracks \\ [], history \\ []) do
    api_key = Application.fetch_env!(:seshat, :anthropic_api_key)

    system =
      if tracks == [] do
        @system_prompt
      else
        track_list =
          tracks
          |> Enum.map(fn t ->
            mute = if t.mute, do: " [muted]", else: ""
            solo = if t.solo, do: " [solo]", else: ""
            "  #{t.index}: \"#{t.name}\" — pan=#{Float.round(t.pan, 2)}, volume=#{Float.round(t.volume, 2)}#{mute}#{solo}"
          end)
          |> Enum.join("\n")

        @system_prompt <>
          "\nCurrent Ableton session state:\n#{track_list}\n" <>
          "Resolve track names/instruments to their index. Use current values as context for relative commands like \"a bit more\" or \"turn it down\"."
      end

    {:ok, response} =
      Req.post(
        "https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"}
        ],
        json: %{
          model: "claude-haiku-4-5-20251001",
          max_tokens: 128,
          system: system,
          messages: history_messages(history) ++ [%{role: "user", content: input}]
        }
      )

    IO.inspect(response.status, label: "anthropic status")
    IO.inspect(response.body, label: "anthropic body")

    with %{status: 200, body: body} <- response,
         [%{"text" => text} | _] <- body["content"],
         {:ok, map} <- Jason.decode(strip_markdown(text)),
         {:ok, command} <- build_command(map) do
      {:ok, command}
    else
      %{status: status, body: body} ->
        Logger.error("Anthropic API error #{status}: #{inspect(body)}")
        {:error, "API error (HTTP #{status})"}
      {:error, %Jason.DecodeError{}} -> {:error, "Could not parse LLM response as JSON"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "Unexpected error parsing command"}
    end
  end

  defp build_command(%{"command" => cmd, "track" => track, "value" => value})
       when cmd in @valid_commands and is_integer(track) do
    {:ok,
     %Command{
       command: String.to_atom(cmd),
       track: track,
       value: value * 1.0
     }}
  end

  defp build_command(%{"command" => "create_track", "track_type" => type, "name" => name})
       when type in ["midi", "audio"] and is_binary(name) do
    {:ok,
     %Command{
       command: :create_track,
       track_type: String.to_atom(type),
       name: name
     }}
  end

  defp build_command(%{"error" => reason}), do: {:error, reason}
  defp build_command(_), do: {:error, "LLM returned an unrecognized command shape"}

  defp history_messages(history) do
    Enum.flat_map(history, fn %{input: input, command: command} ->
      json = encode_command_for_history(command)
      [
        %{role: "user", content: input},
        %{role: "assistant", content: json}
      ]
    end)
  end

  defp encode_command_for_history(%Command{command: :create_track} = cmd) do
    Jason.encode!(%{command: cmd.command, track_type: cmd.track_type, name: cmd.name})
  end

  defp encode_command_for_history(cmd) do
    Jason.encode!(%{command: cmd.command, track: cmd.track, value: cmd.value})
  end

  defp strip_markdown(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```[a-z]*\n?/m, "")
    |> String.replace(~r/```$/, "")
    |> String.trim()
  end
end
