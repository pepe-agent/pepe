defmodule Pepe.Permissions.Grant do
  @moduledoc """
  A permission remembers **what it was given for**.

  Saying "always allow bash" while looking at `ls build/` used to hand the agent bash
  forever: the same permission then covered `rm -rf /`, `sudo`, and `curl | sh`. One tool
  name, one blank cheque, and the human who signed it was looking at a directory listing.

  A grant is now a tool name plus the risks it covers, and a call is allowed only when every
  risk it carries was already approved. Approving `ls` grants bash **for calls that flag no
  risk at all**; the first `rm` flags `deletes` and stops to ask, because nobody ever said
  yes to deleting anything.

  ## The strings you will see in config.json

      "bash:none"                 approved for bash calls that flag no risk
      "bash:deletes+network"      ...that delete files, reach the network, or neither
      "bash:any"                  a blank cheque, written knowingly
      "bash"                      the same blank cheque, from before this existed
      "*"                         every tool, every risk (the owner's own agent)

  The bare name keeps working, because breaking every existing install to make a point is
  not a security improvement. It is simply the widest thing you can write, and now there is
  a narrower one.

  ## What this is not

  It is not a sandbox, and it must not be sold as one. The risks come from
  `Pepe.Permissions.Risk`, which reads the command as text, and text lies: a command can be
  assembled at runtime, base64-decoded, or hidden behind a script the agent wrote a moment
  ago. What this closes is the *blank cheque* - the gap between what a human looked at and
  what they actually signed. It fails closed (an unrecognised risk is never covered by a
  narrower grant), and a container that runs LLM-chosen shell still needs to be a container
  you would be willing to lose.
  """

  alias Pepe.Permissions.Risk

  @wildcard "*"
  @any "any"
  @none "none"

  @doc """
  Does any grant in `grants` cover a call to `tool` carrying `risks`?

  A call is covered when its risks are a subset of a grant's. The empty set is a subset of
  everything, which is why an agent granted `bash:deletes` may still run a harmless `ls`
  without asking: it was trusted with worse.
  """
  @spec covers?([String.t()], String.t(), [Risk.kind()]) :: boolean()
  def covers?(grants, tool, risks) when is_list(grants) do
    Enum.any?(grants, &covers_one?(&1, tool, risks))
  end

  def covers?(_grants, _tool, _risks), do: false

  defp covers_one?(@wildcard, _tool, _risks), do: true

  defp covers_one?(grant, tool, risks) when is_binary(grant) do
    case parse(grant) do
      {^tool, :any} -> true
      {^tool, allowed} -> Enum.all?(risks, &(&1 in allowed))
      _ -> false
    end
  end

  defp covers_one?(_grant, _tool, _risks), do: false

  @doc """
  The grant string to remember, given the risks the human just looked at and said yes to.

      iex> Pepe.Permissions.Grant.for("bash", [])
      "bash:none"
      iex> Pepe.Permissions.Grant.for("bash", [:deletes, :network])
      "bash:deletes+network"
  """
  @spec for(String.t(), [Risk.kind()]) :: String.t()
  def for(tool, []), do: tool <> ":" <> @none

  def for(tool, risks) do
    tool <> ":" <> (risks |> Enum.map(&risk_string/1) |> Enum.sort() |> Enum.join("+"))
  end

  # A known risk stringifies by its atom name; an unrecognised one round-trips through the exact
  # text it came in as. `widen` folds already-parsed risks back through here, and a grant that
  # carried an `{:unknown, _}` (an older Pepe wrote it, or a human typed it) would otherwise hit
  # `to_string/1` on a tuple and crash the turn instead of failing closed as it is meant to.
  defp risk_string({:unknown, text}), do: text
  defp risk_string(kind), do: to_string(kind)

  @doc """
  Fold a new grant into an existing list, widening the one for that tool rather than piling
  up a second entry beside it. A config file nobody can read at a glance is a config file
  nobody audits.
  """
  @spec merge([String.t()], String.t()) :: [String.t()]
  def merge(grants, new) when is_list(grants) do
    {tool, risks} = parse(new)

    if @wildcard in grants do
      # Nothing to widen: this agent already runs everything.
      grants
    else
      {mine, others} = Enum.split_with(grants, &match?({^tool, _}, parse(&1)))
      others ++ [widen(mine, tool, risks)]
    end
  end

  defp widen(existing, tool, risks) do
    all = Enum.map(existing, fn g -> elem(parse(g), 1) end) ++ [risks]

    if Enum.any?(all, &(&1 == :any)) do
      tool <> ":" <> @any
    else
      __MODULE__.for(tool, all |> List.flatten() |> Enum.uniq())
    end
  end

  @doc """
  Split a grant string into `{tool, :any | [risk]}`. A bare name is the widest thing you can
  write, which is what it has always meant.
  """
  @spec parse(String.t()) :: {String.t(), :any | [Risk.kind()]}
  def parse(grant) when is_binary(grant) do
    case String.split(grant, ":", parts: 2) do
      [tool] -> {tool, :any}
      [tool, @any] -> {tool, :any}
      [tool, @none] -> {tool, []}
      [tool, risks] -> {tool, risks |> String.split("+", trim: true) |> Enum.map(&kind/1)}
    end
  end

  # A risk we do not recognise (an older Pepe wrote it, or a human typed it) must never
  # silently widen a grant, so it is kept as-is and simply never matches a real risk kind.
  defp kind(text) do
    case Enum.find(known(), &(to_string(&1) == text)) do
      nil -> {:unknown, text}
      kind -> kind
    end
  end

  defp known,
    do: [
      :inline_eval,
      :download_exec,
      :deletes,
      :elevated,
      :network,
      :writes_file,
      :changes_config,
      :reads_outside,
      :writes_outside,
      :writes_skill,
      :flagged_skill
    ]

  @doc "Human-readable: what a grant actually lets through."
  @spec describe(String.t()) :: String.t()
  def describe(@wildcard), do: "every tool, every risk"

  def describe(grant) do
    case parse(grant) do
      {tool, :any} -> "#{tool}: anything"
      {tool, []} -> "#{tool}: only calls that flag no risk"
      {tool, risks} -> "#{tool}: #{Enum.map_join(risks, ", ", &risk_label/1)}"
    end
  end

  defp risk_label({:unknown, text}), do: text
  defp risk_label(kind), do: Risk.label(kind)
end
