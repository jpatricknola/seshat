defmodule Seshat.Eval.SurfaceTest do
  use ExUnit.Case, async: true

  alias Seshat.Eval.Surface
  alias Seshat.Tools.Definitions

  @base_path Path.expand("../../../priv/routing_eval/surfaces/base-c3096d6.json", __DIR__)

  describe "current/1" do
    # Deliberately re-derived from `__components__(:tool)` rather than compared
    # against `Anubis.Server.Handlers.Tools.handle_list/3`, which is what
    # `current/1` itself calls — that comparison would only prove the function
    # equals itself. What is being pinned is that the snapshot is the *published*
    # object, `title` and all, and not a hand-built
    # `{name, description, inputSchema}` map.
    test "is the tool list Anubis publishes, encoded and sorted by name" do
      expected =
        :tool
        |> Seshat.MCP.Server.__components__()
        |> Enum.sort_by(& &1.name)
        |> Enum.map(&(&1 |> JSON.encode!() |> JSON.decode!()))

      assert Surface.current("abc1234").tools == expected
    end

    test "publishes every defined tool, with a title" do
      surface = Surface.current("abc1234")

      assert length(surface.tools) == length(Definitions.all())
      assert Enum.all?(surface.tools, &Map.has_key?(&1, "title"))
      assert Enum.all?(surface.tools, &Map.has_key?(&1, "inputSchema"))
    end

    test "carries the revision and the server instructions" do
      surface = Surface.current("abc1234")

      assert surface.id == "head"
      assert surface.revision == "abc1234"
      assert surface.instructions == Seshat.Instructions.text()
    end
  end

  describe "the committed base snapshot" do
    test "is the 67-tool surface from before the consolidation" do
      surface = Surface.load!(@base_path)

      assert surface.id == "base-c3096d6"
      assert surface.revision == "c3096d6"
      assert length(surface.tools) == 67

      names = Surface.tool_names(surface)

      assert "set_master_volume" in names
      assert "set_return_track_mute" in names
      assert "remove_notes" in names
      refute "set_mixer" in names
      refute "edit_notes" in names
    end

    test "carries the instructions the model would have been sent" do
      surface = Surface.load!(@base_path)

      assert is_binary(surface.instructions)
      assert surface.instructions =~ "Speak music"
    end
  end

  describe "kind/2" do
    # The split has to hold identically on both surfaces or the mutation counts
    # aren't comparable between them.
    test "reads, views and mutations are classified the same on both surfaces" do
      for surface <- [Surface.current("abc1234"), Surface.load!(@base_path)] do
        assert Surface.kind(surface, "get_session_state") == :read
        assert Surface.kind(surface, "search_library") == :read
        assert Surface.kind(surface, "list_browser_items") == :read
        assert Surface.kind(surface, "reindex_library") == :read

        for view <- ~w(show_view hide_view select_track select_scene) do
          assert Surface.kind(surface, view) == :view, "#{view} on #{surface.id}"
          assert view in Surface.tool_names(surface)
        end

        assert Surface.kind(surface, "write_midi_notes") == :mutation
        assert Surface.kind(surface, "load_device") == :mutation
      end
    end
  end

  describe "dump/1 and load!/1" do
    @tag :tmp_dir
    test "round trip preserves the tools verbatim", context do
      surface = Surface.current("abc1234")
      path = Path.join(context.tmp_dir, "surface.json")
      File.write!(path, Surface.dump(surface))

      loaded = Surface.load!(path)

      assert loaded.tools == surface.tools
      assert loaded.instructions == surface.instructions
      assert loaded.revision == "abc1234"
    end

    test "keys are sorted so a committed snapshot diffs line by line" do
      json = Surface.dump(Surface.current("abc1234"))
      keys = Regex.scan(~r/^  "(\w+)":/m, json, capture: :all_but_first) |> List.flatten()

      assert keys == Enum.sort(keys)
    end
  end

  describe "contract_digest/1" do
    test "changes when the instructions change and ignores the capture time" do
      one = Surface.current("abc1234")
      two = %{one | captured_at: "1999-01-01T00:00:00Z", id: "other", revision: "zzz"}

      assert Surface.contract_digest(one) == Surface.contract_digest(two)

      changed = %{one | instructions: one.instructions <> " and one more rule"}
      refute Surface.contract_digest(one) == Surface.contract_digest(changed)
    end
  end
end
