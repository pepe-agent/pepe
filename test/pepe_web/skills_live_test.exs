defmodule PepeWeb.SkillsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Skills.Settings

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_skills_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp write(home, name, extra) do
    File.write!(
      Path.join([home, "skills", name <> ".md"]),
      "---\nname: #{name}\ndescription: Use when #{name}.\n#{extra}---\n\nSteps.\n"
    )
  end

  test "lists skills with where they come from, why one is not offered and what one needs", %{home: home} do
    write(home, "elsewhere", "platforms: [plan9]\n")
    write(home, "needs-key", "required_environment_variables: [PEPE_TEST_SURELY_UNSET_KEY]\n")

    {:ok, _view, html} = live(conn(), "/skills")

    assert html =~ "elsewhere"
    assert html =~ "For another operating system"
    assert html =~ "needs-key"
    assert html =~ "needs PEPE_TEST_SURELY_UNSET_KEY"
    assert html =~ "Built in"
    assert html =~ "Yours"
  end

  test "a skill can be turned off everywhere and on again", %{home: home} do
    write(home, "flip", "")
    {:ok, view, _html} = live(conn(), "/skills")

    html = view |> element(~s(button[phx-click="skill_off"][phx-value-name="flip"])) |> render_click()
    assert Settings.disabled() == ["flip"]
    assert html =~ "Turn on"

    view |> element(~s(button[phx-click="skill_on"][phx-value-name="flip"])) |> render_click()
    assert Settings.disabled() == []
  end

  test "a skill can be turned off on one channel and back on", %{home: home} do
    write(home, "chan", "")
    {:ok, view, _html} = live(conn(), "/skills")

    view |> form("#skill-channel-chan", %{"channel" => "telegram"}) |> render_submit()
    assert Settings.channel_disabled("telegram") == ["chan"]

    view |> element(~s(button[phx-click="skill_channel_on"][phx-value-name="chan"][phx-value-channel="telegram"])) |> render_click()
    assert Settings.channel_disabled("telegram") == []
  end

  test "Check shows the specification report", %{home: home} do
    File.write!(Path.join([home, "skills", "no-header.md"]), "just text\n")
    {:ok, view, _html} = live(conn(), "/skills")

    html = view |> element(~s(button[phx-click="skill_check"][phx-value-name="no-header"])) |> render_click()

    assert html =~ "Not valid"
    assert html =~ "header_missing"
  end
end
