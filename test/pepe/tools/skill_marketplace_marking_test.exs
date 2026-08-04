defmodule Pepe.Tools.SkillMarketplaceMarkingTest do
  @moduledoc """
  A marketplace-installed skill's content is wrapped in the same untrusted-content marker
  `fetch_url`/`web_search` results carry (see `Pepe.Security.ExternalContent`) UNLESS it came
  from the bundled, in-repo registry (`trust_level: "official"`) - a hand-authored or built-in
  skill (no marketplace provenance at all) is never marked, matching how a built-in skill is
  implicitly trusted today.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools.Skill

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_skmark_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  test "a built-in skill is never marked" do
    {:ok, content} = Skill.run(%{"name" => "install-tool"}, %{})
    refute content =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
  end

  test "a hand-authored user skill (no marketplace provenance) is never marked", %{home: home} do
    File.write!(Path.join([home, "skills", "my-skill.md"]), "Use when doing my thing.\n")

    {:ok, content} = Skill.run(%{"name" => "my-skill"}, %{})
    refute content =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
  end

  test "a community-trust marketplace skill is marked untrusted when read", %{home: home} do
    File.write!(Path.join([home, "skills", "community-skill.md"]), "Use when doing the community thing.\n")

    Config.put_installed_skill("community-skill", %{
      "source" => "https://example.com/community-skill.md",
      "hash" => "sha256:abc",
      "trust_level" => "community",
      "installed_at" => "2026-01-01T00:00:00Z"
    })

    {:ok, content} = Skill.run(%{"name" => "community-skill"}, %{})
    assert content =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
    assert content =~ "source: skill:community-skill"
    assert content =~ "Use when doing the community thing."
  end

  test "an official-trust marketplace skill (from the bundled registry) is not marked", %{home: home} do
    File.write!(Path.join([home, "skills", "official-skill.md"]), "Use when doing the official thing.\n")

    Config.put_installed_skill("official-skill", %{
      "source" => "priv/skills_registry.json",
      "hash" => "sha256:abc",
      "trust_level" => "official",
      "installed_at" => "2026-01-01T00:00:00Z"
    })

    {:ok, content} = Skill.run(%{"name" => "official-skill"}, %{})
    refute content =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
  end
end
