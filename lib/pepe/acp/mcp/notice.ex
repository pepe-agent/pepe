defmodule Pepe.ACP.Mcp.Notice do
  @moduledoc """
  The sentences the person in the editor reads about their MCP servers: one that was
  refused, one that did not start, tools that were left out.

  `Pepe.ACP.Mcp.Manager` keeps these as tagged tuples, because it is one shared process
  with no idea what language anybody reads. The wording happens here, at the moment a turn
  asks for it, in the caller's own process and therefore in the caller's locale.
  """

  use Gettext, backend: Pepe.Gettext

  alias Pepe.ACP.Mcp.Failure

  @type t ::
          {:rejected, String.t(), String.t()}
          | {:failed, String.t(), String.t(), term()}
          | {:truncated, String.t(), non_neg_integer(), pos_integer()}
          | {:schema, String.t(), String.t()}

  @doc "The sentence for one notice."
  @spec text(t()) :: String.t()
  def text({:rejected, name, reason}),
    do: gettext("MCP server `%{name}` from your editor was not used: %{reason}.", name: name, reason: reason)

  def text({:failed, name, where, reason}) do
    gettext("MCP server `%{name}`%{where} from your editor %{why}. Its tools are not available in this session.",
      name: name,
      where: where,
      why: Failure.describe(reason)
    )
  end

  def text({:truncated, name, total, max}) do
    gettext("MCP server `%{name}` offers %{total} tools; only the first %{max} are available in this session.",
      name: name,
      total: total,
      max: max
    )
  end

  def text({:schema, name, tool}) do
    gettext("MCP server `%{name}`: the input schema of the tool `%{tool}` is too large to pass on, so the tool is offered without one.",
      name: name,
      tool: tool
    )
  end
end
