defmodule SeshatWeb.AssistantLive do
  use SeshatWeb, :live_view

  alias Seshat.Agent

  def mount(_params, _session, socket) do
    {:ok, assign(socket, input: "", log: [], status: :idle, last_input: "", history: [])}
  end

  def handle_event("submit", %{"input" => input}, socket) do
    input = String.trim(input)

    if input == "" do
      {:noreply, socket}
    else
      history = socket.assigns.history

      socket =
        socket
        |> assign(status: :thinking, input: "", last_input: input)
        |> start_async(:parse_and_send, fn -> Agent.run(input, history) end)

      {:noreply, socket}
    end
  end

  def handle_async(:parse_and_send, {:ok, {:ok, result}}, socket) do
    entry = %{
      input: socket.assigns.last_input,
      result: :ok,
      response: result.response,
      commands_executed: result.commands_executed
    }

    history = Map.get(result, :messages, socket.assigns.history)

    {:noreply, assign(socket, status: :idle, log: [entry | socket.assigns.log], history: history)}
  end

  def handle_async(:parse_and_send, {:ok, {:error, reason}}, socket) do
    entry = %{input: socket.assigns.last_input, result: :error, message: reason}
    {:noreply, assign(socket, status: :idle, log: [entry | socket.assigns.log])}
  end

  def handle_async(:parse_and_send, {:exit, reason}, socket) do
    entry = %{input: socket.assigns.last_input, result: :error, message: "Crashed: #{inspect(reason)}"}
    {:noreply, assign(socket, status: :idle, log: [entry | socket.assigns.log])}
  end

  defp format_success(entry) do
    parts = []

    parts =
      case entry.commands_executed do
        [] -> parts
        cmds -> parts ++ Enum.map(cmds, fn c -> "#{c.tool}(#{inspect(c.input)}): #{c.result}" end)
      end

    parts =
      case entry.response do
        nil -> parts
        text -> parts ++ [text]
      end

    Enum.join(parts, "\n")
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
                {if entry.result == :ok, do: format_success(entry), else: entry.message}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
