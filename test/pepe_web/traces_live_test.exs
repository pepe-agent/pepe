defmodule PepeWeb.TracesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Trace

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_traces_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # record one run to show up in the list, in this process's pdict
    Trace.start("assistant", "api:1", "read the readme")
    Trace.event({:tool_call, "read_file", ~s({"path":"README.md"})})
    Trace.event({:tool_result, "read_file", "the contents"})
    Trace.event({:assistant, "Here you go."})
    id = Trace.finish({:ok, "Here you go.", []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_trace)
    end)

    %{id: id}
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "lists a recorded run" do
    {:ok, _view, html} = live(conn(), "/traces")
    assert html =~ "assistant"
    assert html =~ "read_file"
  end

  test "replays a run step by step" do
    {:ok, view, _html} = live(conn(), "/traces")
    id = Trace.recent("default") |> hd() |> Map.fetch!("id")
    html = render_click(view, "open", %{"scope" => "default", "id" => id})

    assert html =~ "read the readme"
    assert html =~ "read_file"
    assert html =~ "Here you go."
  end
end
