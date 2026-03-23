defmodule SeshatWeb.AssistantLive do
  use SeshatWeb, :live_view

  alias Seshat.Commands.{Parser, Registry}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, input: "", log: [], status: :idle, last_input: "")}
  end

  def handle_event("submit", %{"input" => input}, socket) do
    input = String.trim(input)

    if input == "" do
      {:noreply, socket}
    else
      log = socket.assigns.log

      socket =
        socket
        |> assign(status: :thinking, input: "", last_input: input)
        |> start_async(:parse_and_send, fn -> run(input, log) end)

      {:noreply, socket}
    end
  end

  def handle_async(:parse_and_send, {:ok, result}, socket) do
    entry = Map.put(result, :input, socket.assigns.last_input)
    {:noreply, assign(socket, status: :idle, log: [entry | socket.assigns.log])}
  end

  def handle_async(:parse_and_send, {:exit, reason}, socket) do
    entry = %{input: socket.assigns.last_input, result: :error, message: "Crashed: #{inspect(reason)}"}
    {:noreply, assign(socket, status: :idle, log: [entry | socket.assigns.log])}
  end

  defp run(input, log) do
    tracks = Seshat.Session.State.tracks()
    history = log |> Enum.filter(&(&1.result == :ok)) |> Enum.take(5) |> Enum.reverse()

    with {:ok, command} <- Parser.parse(input, tracks, history),
         :ok <- Registry.execute(command) do
      %{result: :ok, command: command}
    else
      {:error, reason} -> %{result: :error, message: reason}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200 flex flex-col items-center justify-start p-8">
      <div class="w-full max-w-2xl space-y-6">
        <h1 class="text-3xl font-bold text-center">Ableton Assistant</h1>

        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <form phx-submit="submit">
              <div class="flex gap-2">
                <input
                  type="text"
                  name="input"
                  value={@input}
                  placeholder='e.g. "pan track 1 to the left"'
                  class="input input-bordered flex-1"
                  disabled={@status == :thinking}
                  autofocus
                />
                <button type="submit" class="btn btn-primary" disabled={@status == :thinking}>
                  {if @status == :thinking, do: "…", else: "Send"}
                </button>
              </div>
            </form>
          </div>
        </div>

        <div class="space-y-2">
          <div
            :for={entry <- @log}
            class={"alert " <> if(entry.result == :ok, do: "alert-success", else: "alert-error")}
          >
            <div class="flex flex-col gap-1">
              <span class="font-mono text-sm">{entry.input}</span>
              <span class="text-xs opacity-60">
                {if entry.result == :ok, do: inspect(entry.command), else: entry.message}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
