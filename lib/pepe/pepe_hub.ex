defmodule Pepe.PepeHub do
  @moduledoc """
  Resolves an `@handle/name` reference - or a full package page URL copied straight off the
  site - against PepeHub (https://hub.pepe-agent.com), Pepe's plugin/skill registry, into a
  concrete, versioned download URL. This is the one HTTP call both `Pepe.Plugins.install/2`
  and `Pepe.Skills.Marketplace.resolve/1` need before handing off to `Pepe.Sourcing`, which
  does the actual download/stage - this module never touches a filesystem.

  A PepeHub package is namespaced like an npm scoped package (`@handle/name`), and that is
  also exactly the tail of its own public page (`hub.pepe-agent.com/packages/@handle/name`) -
  so the shorthand someone types and the address bar of the page they were just looking at
  are the same string. `parse/1` accepts either and returns the same canonical name either
  way, which is what makes both forms work identically everywhere this module is used.
  """

  @default_base_url "https://hub.pepe-agent.com"
  @name_re ~r/\A@[\w.-]+\/[\w.-]+\z/

  # Overridable only for tests (a local Bandit server instead of the real hub) - never a
  # real runtime setting, so there is no config.json field or CLI flag for it.
  defp base_url, do: Application.get_env(:pepe, :pepe_hub_base_url, @default_base_url)

  @doc "Is `str` a PepeHub reference - a bare `@handle/name` shorthand or a full package page URL?"
  @spec reference?(String.t()) :: boolean()
  def reference?(str), do: match?({:ok, _}, parse(str))

  @doc "Extract the canonical `@handle/name` from a bare shorthand or a full PepeHub package URL."
  @spec parse(String.t()) :: {:ok, String.t()} | :error
  def parse(str) when is_binary(str) do
    if Regex.match?(@name_re, str), do: {:ok, str}, else: parse_url(str)
  end

  defp parse_url(str) do
    hub_host = URI.parse(base_url()).host

    case URI.parse(str) do
      %URI{host: ^hub_host, path: "/packages/" <> rest} when is_binary(rest) and rest != "" ->
        name = rest |> String.trim_trailing("/") |> URI.decode()
        if Regex.match?(@name_re, name), do: {:ok, name}, else: :error

      _ ->
        :error
    end
  end

  @doc """
  The package slug alone (no `@handle/`), for placing an installed skill locally - a skill
  is referenced by bare name everywhere else in Pepe (the `skill` tool, `/skill NAME`), so
  the scope is dropped at install time, not carried into the filename. Returns `name_or_url`
  unchanged when it isn't a PepeHub reference at all.
  """
  @spec local_name(String.t()) :: String.t()
  def local_name(name_or_url) do
    case parse(name_or_url) do
      {:ok, name} -> name |> String.split("/", parts: 2) |> List.last()
      :error -> name_or_url
    end
  end

  @doc """
  Resolve a PepeHub reference to its latest published version. `{:ok, %{kind:,
  download_url:, trust:}}` - `kind` is `"plugin"` or `"skill"` (PepeHub packages both under
  one namespace; the caller checks this matches what it's installing), `trust` is
  `"official"` or `"community"` (PepeHub's own manual curation flag - see its README's
  "Marcar um pacote como oficial" - never self-declared by the package). `{:error, reason}`
  on anything else: not a PepeHub reference, not found, nothing published yet, or PepeHub
  unreachable.
  """
  @spec resolve(String.t()) ::
          {:ok, %{kind: String.t(), download_url: String.t(), trust: String.t()}} | {:error, term()}
  def resolve(str) do
    with {:ok, name} <- parse(str),
         {:ok, meta} <- fetch_metadata(name) do
      case meta do
        %{"latestVersion" => version, "kind" => kind} when is_binary(version) and is_binary(kind) ->
          {:ok, %{kind: kind, download_url: download_url(name, version), trust: trust(meta)}}

        _ ->
          {:error, :no_published_version}
      end
    else
      :error -> {:error, :invalid_reference}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trust(%{"official" => true}), do: "official"
  defp trust(_meta), do: "community"

  defp fetch_metadata(name) do
    case Req.get(metadata_url(name), receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} when is_binary(body) -> decode_json(body)
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_response}
    end
  end

  # `name` only ever reaches here already validated by @name_re (letters, digits, `.`, `_`,
  # `-`, one `/`, one leading `@`) - every one of those is a plain, safe path character, so
  # no percent-encoding step is needed, and the literal `@`/`/` are exactly what PepeHub's
  # own [owner]/[pkg] route expects to split on.
  defp metadata_url(name), do: base_url() <> "/api/v1/packages/" <> name
  defp download_url(name, version), do: base_url() <> "/api/v1/packages/" <> name <> "/versions/" <> version <> "/download"
end
