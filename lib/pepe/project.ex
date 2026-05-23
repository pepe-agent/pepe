defmodule Pepe.Project do
  @moduledoc """
  Multi-tenant scoping.

  An agent's identity is a **handle**. In the **root** scope it's a bare name
  (`"vendas"`) - exactly what a single-tenant install has always used, so nothing
  changes for setups that never touch projects. Inside a project it's qualified as
  `"project/name"` (`"acme/vendas"`), and the same bare name can be reused across
  projects (`"acme/vendas"` and `"globex/vendas"` are different agents).

  The handle is the identity used everywhere agents are keyed - config, workspace
  directory, session keys, the `Pepe.Agent.Registry`, `can_message` routes, cron
  and bot bindings - so isolation rides along for free: a project handle carries its
  project prefix through all of them. The scope-aware behaviour lives in just a few
  places (config lookups/listing, workspace paths, and the cross-project guard in
  `Pepe.Tools.SendToAgent`).

  The **root** scope (`project == nil`) is what every command operates on when no
  `--project` is given.
  """

  @separator "/"

  @doc "The handle separator (`\"/\"`), forbidden inside a project or agent name."
  def separator, do: @separator

  @doc "Build a handle from an optional project and a bare name."
  @spec handle(String.t() | nil, String.t()) :: String.t()
  def handle(project, name) when project in [nil, ""], do: to_string(name)
  def handle(project, name), do: "#{project}#{@separator}#{name}"

  @doc "Split a handle into `{project | nil, bare_name}`."
  @spec split(String.t()) :: {String.t() | nil, String.t()}
  def split(handle) when is_binary(handle) do
    case String.split(handle, @separator, parts: 2) do
      [project, name] when project != "" and name != "" -> {project, name}
      _ -> {nil, handle}
    end
  end

  @doc "The project a handle belongs to, or `nil` for the root scope."
  @spec of(String.t()) :: String.t() | nil
  def of(handle), do: handle |> to_string() |> split() |> elem(0)

  @doc "The bare (display) name of a handle, without any project prefix."
  @spec name_of(String.t()) :: String.t()
  def name_of(handle), do: handle |> to_string() |> split() |> elem(1)

  @doc "Are two handles in the same scope (same project, or both root)?"
  @spec same_scope?(String.t(), String.t()) :: boolean()
  def same_scope?(a, b), do: of(a) == of(b)

  @doc """
  Resolve a possibly-bare `to` handle against a `from` handle's scope: a bare name
  is qualified into the sender's project, an already-qualified handle is left as-is.
  So inside `acme`, `"vendas"` means `"acme/vendas"`.
  """
  @spec qualify(String.t(), String.t()) :: String.t()
  def qualify(to, from) do
    case split(to) do
      {nil, name} -> handle(of(from), name)
      _ -> to
    end
  end

  @doc """
  Is `name` valid as a project or agent name segment? Alphanumerics, `-` and `_`
  only - no separator, no dots or spaces (it becomes a path segment and a handle
  part).
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    # \A...\z, not ^...$: the line anchors would accept a trailing newline ("foo\n"), letting a
    # crafted segment slip past the path-traversal guard. Anchor to the whole string.
    Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, name)
  end

  def valid_name?(_), do: false
end
