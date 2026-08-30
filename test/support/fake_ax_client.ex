defmodule Seshat.Test.FakeAXClient do
  @moduledoc """
  A scripted stand-in for `Seshat.AX.Client`.

  `Seshat.Tools.Handlers` resolves its AX client through `:ax_client`, so
  installing this module lets the two audio-output handler clauses be dispatched
  for real — validation, dispatch, formatting, error rendering — without any of
  it reaching macOS Accessibility, Live's Settings window, or a real user's
  audio hardware.

  Each call is also forwarded to the installing process as
  `{:ax_call, operation, arguments}`, so a test can assert *what* was asked as
  well as what came back — the exact device name matters here, since exact-name
  matching is the contract between the two tools.
  """

  @behaviour Seshat.AX.Client

  @doc """
  Point `Seshat.Tools.Handlers` at this module for the duration of the test.

  `responses` maps `:list_outputs` / `:set_output` / `:convert` to the value the
  fake should return — including the failure shapes, so every error rendering is
  reachable without a real failure to provoke.
  """
  @spec install(map()) :: :ok
  def install(responses) do
    Application.put_env(:seshat, :ax_client, __MODULE__)
    Application.put_env(:seshat, :fake_ax, Map.put_new(responses, :owner, self()))

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:seshat, :ax_client)
      Application.delete_env(:seshat, :fake_ax)
    end)

    :ok
  end

  @impl true
  def list_outputs, do: respond(:list_outputs, [])

  @impl true
  def set_output(device), do: respond(:set_output, [device])

  @impl true
  def convert(command), do: respond(:convert, [command])

  defp respond(operation, arguments) do
    config = Application.get_env(:seshat, :fake_ax, %{})

    if owner = config[:owner], do: send(owner, {:ax_call, operation, arguments})

    Map.get_lazy(config, operation, fn ->
      {:error,
       %{
         code: :ax_failure,
         message: "No fake response was configured for #{operation}.",
         devices: nil,
         current: nil
       }}
    end)
  end
end
