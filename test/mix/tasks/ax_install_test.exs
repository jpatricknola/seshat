defmodule Mix.Tasks.Ax.InstallTest do
  @moduledoc """
  What can be checked about the native build without being on macOS.

  `mix ax.install` compiles `native/seshat_ax/main.m` against AppKit, so the
  Ubuntu suite cannot run it and cannot even build its product. The macOS CI job
  does both — which means the *command* is duplicated in two places, and a
  divergence would be invisible: the task would keep installing a helper CI never
  built the same way. That is what these tests watch.
  """

  use ExUnit.Case, async: true

  @task_source "lib/mix/tasks/ax.install.ex"
  @workflow ".github/workflows/ci.yml"
  @helper_source "native/seshat_ax/main.m"

  test "the helper source the task compiles exists" do
    assert File.regular?(@helper_source)
  end

  test "the task and the macOS CI job compile with the same flags" do
    task = File.read!(@task_source)
    workflow = File.read!(@workflow)

    flags = word_list(task, "@clang_flags") ++ word_list(task, "@frameworks")

    assert "-Werror" in flags, "warnings-as-errors is the point of the CI build"

    helper_job = String.split(workflow, "Compile native/seshat_ax/main.m") |> List.last()

    for flag <- flags do
      assert helper_job =~ flag,
             """
             mix ax.install compiles with #{flag} but the macOS CI job does not.

             The job exists to build the helper the way the task does. Update
             #{@workflow} to match #{@task_source}, or this build proves
             something no user will ever run.
             """
    end
  end

  test "the CI job checks the permission protocol, not just the exit status" do
    workflow = File.read!(@workflow)

    assert workflow =~ "permission_required"
    assert workflow =~ "protocol_version"
  end

  # `~w(-fobjc-arc -Wall ...)` in the task's source. Read out of the text rather
  # than the module because they are private attributes — and reading the text is
  # the point: it is the same file a person would edit.
  defp word_list(source, attribute) do
    [_, body] = Regex.run(~r/#{attribute} ~w\(([^)]*)\)/, source)

    String.split(body, ~r/\s+/, trim: true)
  end
end
