defmodule Pepe.Tools.SkillManage do
  @moduledoc """
  Write skills: create, rewrite, patch, add or remove a support file, retire.

  The only way an agent should change a skill. It goes through `Pepe.Skills.Manage`, which
  checks whose the skill is, requires a fresh read before a background write, lints and
  security-scans what is written, and leaves a ledger row and a copy of the replaced bytes so
  the change can be undone. The permission gate still applies: in a conversation the person
  is asked (`writes_skill`, or `flagged_skill` when the scan does not like the content), and a
  background review is granted `writes_skill` only, so a flagged skill stops even unattended.

  Whether a call is a person-present one or a background one is read from the run's context
  (`:review_run`), never from anything the model can supply.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Skills.Manage

  @actions ~w(create edit patch delete write_file remove_file)

  @impl true
  def name, do: "skill_manage"

  @impl true
  def spec do
    function(
      "skill_manage",
      """
      Create and maintain skills: reusable procedures you (or another run) read later with the `skill` tool. \
      Actions: `create` (name + content: a full SKILL.md), `edit` (rewrite the whole SKILL.md), \
      `patch` (replace `old_string` with `new_string` in SKILL.md, or in `file_path`), \
      `write_file` / `remove_file` (a support file under references/, templates/, scripts/ or assets/), \
      `delete` (archives the skill, it can be restored). \
      A skill is a class of task, not one incident: name it for the class ("release-checklist", not "fix-bug-482"), \
      make the first line a short "Use when ..." trigger, write rules and the reason for each, and drop the story. \
      Prefer patching an existing skill over creating a near-duplicate. \
      Only skills an agent wrote are yours to change unattended; a person's own, an installed and a bundled skill are not, \
      and say so if one is wrong instead of trying. Read the skill (`skill` tool, or `read_file` for a support file) \
      before you patch it: an unattended write without a fresh read is refused. \
      The result lists lint findings: fix them in the same turn.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => @actions},
          "name" => %{"type" => "string", "description" => "Skill name: lowercase letters, digits, hyphens, underscores."},
          "content" => %{"type" => "string", "description" => "Full SKILL.md text, for create and edit."},
          "old_string" => %{"type" => "string", "description" => "Exact text to replace, for patch. Must match once unless replace_all."},
          "new_string" => %{"type" => "string", "description" => "Replacement text, for patch. Empty removes the match."},
          "replace_all" => %{"type" => "boolean", "description" => "Patch every match instead of requiring exactly one."},
          "file_path" => %{
            "type" => "string",
            "description" => "Support file, relative to the skill: references/x.md, scripts/y.sh. For patch, remove_file and write_file."
          },
          "file_content" => %{"type" => "string", "description" => "The support file's text, for write_file."},
          "absorbed_into" => %{
            "type" => "string",
            "description" => "For delete during consolidation: the skill this one's content now lives in."
          }
        },
        "required" => ["action", "name"]
      }
    )
  end

  @impl true
  def run(%{"action" => action, "name" => name} = args, ctx) when action in @actions and is_binary(name) do
    opts = [actor: actor(ctx), origin: origin(ctx), run: ctx[:review_run]]

    case dispatch(action, name, args, opts, ctx) do
      {:ok, result} -> {:ok, render(result)}
      {:error, message} -> {:error, message}
    end
  end

  def run(%{"action" => action}, _ctx) when is_binary(action),
    do: {:error, "unknown action '#{action}'; use one of: #{Enum.join(@actions, ", ")}."}

  def run(_args, _ctx), do: {:error, "skill_manage needs `action` and `name`."}

  defp dispatch("create", name, %{"content" => content}, opts, _ctx), do: Manage.create(name, content, opts)
  defp dispatch("edit", name, %{"content" => content}, opts, _ctx), do: Manage.edit(name, content, opts)

  defp dispatch("patch", name, %{"old_string" => old, "new_string" => new} = args, opts, _ctx) do
    Manage.patch(name, old, new, [{:file_path, args["file_path"]}, {:replace_all, args["replace_all"] == true} | opts])
  end

  defp dispatch("write_file", name, %{"file_path" => path, "file_content" => text}, opts, _ctx),
    do: Manage.write_file(name, path, text, opts)

  defp dispatch("remove_file", name, %{"file_path" => path}, opts, _ctx), do: Manage.remove_file(name, path, opts)

  defp dispatch("delete", name, args, opts, ctx) do
    Manage.delete(name, [
      {:absorbed_into, args["absorbed_into"]},
      {:require_target, background?(ctx) and ctx[:review_actor] == "curator"} | opts
    ])
  end

  defp dispatch(action, _name, _args, _opts, _ctx),
    do: {:error, "`#{action}` is missing an argument; see the tool description for what it needs."}

  # Background when the run carries a review id, and only then: nothing in the arguments can
  # claim it, so a model cannot ask to be treated as a person.
  defp origin(ctx), do: if(background?(ctx), do: :background, else: :foreground)
  defp background?(ctx), do: is_binary(ctx[:review_run])

  defp actor(ctx) do
    cond do
      is_binary(ctx[:review_actor]) -> ctx[:review_actor]
      match?(%{name: name} when is_binary(name), ctx[:agent]) -> "agent:" <> ctx[:agent].name
      true -> "agent"
    end
  end

  defp render(%{message: message, findings: findings} = result) do
    ledger = if result[:entry], do: " (ledger entry #{result.entry}; `pepe skill undo #{result.entry}` reverses it)", else: ""
    lint = if findings == [], do: "", else: "\n\nLint findings to fix:\n" <> Pepe.Skills.Lint.format(findings)
    message <> ledger <> lint
  end
end
