defmodule Pepe.Tools.Skill do
  @moduledoc "Read a skill - an on-demand instruction doc that teaches the agent a procedure."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "skill"

  @impl true
  def spec do
    function(
      "skill",
      "Read a skill: a step-by-step instruction doc. Use it when the user asks for something a listed skill covers (e.g. installing a tool) - read the skill, then follow it. Pass the skill `name` from the list in your context.",
      %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The skill name to read."}
        },
        "required" => ["name"]
      }
    )
  end

  @impl true
  def run(%{"name" => name}, ctx) when is_binary(name) do
    opts = [cwd: ctx[:cwd], channel: channel(ctx), agent: ctx[:agent], offer: false]

    case Pepe.Skills.read(name, opts) do
      {:ok, content} ->
        Pepe.Skills.Stats.bump_view(name)
        {:ok, mark_if_community(name, content)}

      _ ->
        {:error, "no skill named #{name}"}
    end
  end

  def run(_args, _ctx), do: {:error, "missing 'name'"}

  defp channel(ctx) do
    case ctx[:source] || ctx[:session_key] do
      value when is_binary(value) -> value |> String.split(":", parts: 2) |> hd()
      _ -> nil
    end
  end

  # A hand-authored or built-in skill (no marketplace provenance at all) is implicitly
  # trusted, same as always. A skill installed from the bundled, in-repo registry is
  # "official" - reviewed before it ever landed in this codebase. Anything resolved through
  # an operator-added tap, or installed directly from a --source URL, is "community": it
  # passed the Sentinel's static scan at install time, but that scan can miss a subtler
  # injection, so it's marked the same way fetch_url/web_search results already are until a
  # human has actually reviewed it (see Pepe.Security.ExternalContent).
  defp mark_if_community(name, content) do
    case Pepe.Config.installed_skill(name) do
      %{"trust_level" => "community"} ->
        Pepe.Security.ExternalContent.mark_untrusted("skill:#{name} (community tap, unaudited)", content)

      _ ->
        content
    end
  end
end
