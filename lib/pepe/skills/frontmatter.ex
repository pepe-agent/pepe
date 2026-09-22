defmodule Pepe.Skills.Frontmatter do
  @moduledoc """
  Reads the YAML metadata header of a skill's entry doc and turns it into typed fields.

  The header format is the open interchange one (a `---` fenced block ahead of the
  instructions, `name` and `description` required by the spec), so a skill written for any
  compatible tool reads here unchanged. Everything Pepe understands beyond the two
  required keys is optional and is looked up in three places, most specific first:
  `metadata.pepe.<key>`, then top level `<key>`, then `metadata.<key>` (the spec's own
  free-form map, whose values are strings - so a list may arrive as `"a, b"`).

  Parsing is forgiving in exactly one way: a plain value that happens to contain `: ` or
  ` #` (a `description: Use when: the user sends a PDF`, extremely common in the wild and a
  hard YAML error) is retried with that value quoted. Anything else that does not parse is
  "no header", never an exception - a third-party skill is precisely where malformed input
  is to be expected.
  """

  defstruct meta: %{}, body: "", has_header?: false, yaml: :none

  @type t :: %__MODULE__{
          meta: map(),
          body: String.t(),
          has_header?: boolean(),
          yaml: :ok | :recovered | :invalid | :none
        }

  @doc """
  Split a doc into its header and body.

  `yaml` says how the header read: `:ok`, `:recovered` (parsed after quoting a plain value
  that held a colon), `:invalid` (fenced like a header but not a YAML map, returned as body
  untouched) or `:none` (no header at all).
  """
  @spec parse(String.t()) :: t()
  def parse("﻿" <> rest), do: parse(rest)
  def parse("---\n" <> rest = content), do: split(rest, content)
  def parse("---\r\n" <> rest = content), do: split(rest, content)
  def parse(content) when is_binary(content), do: %__MODULE__{body: content}

  defp split(rest, original) do
    case Regex.split(~r/^---[ \t]*\r?$/m, rest, parts: 2) do
      [yaml, body] -> read_yaml(yaml, strip_newline(body), original)
      _ -> %__MODULE__{body: original, yaml: :invalid}
    end
  end

  defp strip_newline(body), do: body |> String.replace_prefix("\r\n", "") |> String.replace_prefix("\n", "")

  defp read_yaml(yaml, body, original) do
    case yaml_map(yaml) do
      {:ok, map} ->
        %__MODULE__{meta: map, body: body, has_header?: true, yaml: :ok}

      :error ->
        case yaml |> requote() |> yaml_map() do
          {:ok, map} -> %__MODULE__{meta: map, body: body, has_header?: true, yaml: :recovered}
          :error -> %__MODULE__{body: original, yaml: :invalid}
        end
    end
  end

  # The parser raises (rather than returning an error tuple) on some malformed input.
  defp yaml_map(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # Quote a top-level plain scalar that carries `: ` or ` #`. Values that already open with
  # quote, flow or block syntax are left exactly as written: those are real YAML, and an
  # unterminated `[` must stay an error.
  defp requote(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.map_join("\n", &requote_line/1)
  end

  defp requote_line(line) do
    case Regex.run(~r/^([A-Za-z0-9_.-]+):[ \t]+(.+?)\r?$/, line) do
      [_, key, value] -> if plain_with_colon?(value), do: ~s(#{key}: #{quote_scalar(value)}), else: line
      _ -> line
    end
  end

  defp plain_with_colon?(value) do
    not String.starts_with?(value, ["\"", "'", "[", "{", "|", ">", "&", "*", "!", "%", "@", "`"]) and
      (String.contains?(value, ": ") or String.contains?(value, " #"))
  end

  defp quote_scalar(value), do: ~s("#{value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}")

  # ---------------------------------------------------------------------------------------
  # typed fields
  # ---------------------------------------------------------------------------------------

  @doc """
  The fields Pepe reads from a parsed header, normalized: lists are lists of strings,
  absent things are `nil` or `[]`. `name` is the header's own, unvalidated.
  """
  @spec fields(map()) :: map()
  def fields(meta) when is_map(meta) do
    %{
      name: string(get(meta, "name")),
      description: string(get(meta, "description")),
      version: string(get(meta, "version")),
      license: string(get(meta, "license")),
      compatibility: string(get(meta, "compatibility")),
      allowed_tools: words(get(meta, "allowed-tools") || get(meta, "allowed_tools")),
      tags: list(get(meta, "tags")),
      related_skills: list(get(meta, "related_skills") || get(meta, "related-skills")),
      platforms: list(get(meta, "platforms")),
      environments: list(get(meta, "environments")),
      requires_tools: list(get(meta, "requires_tools")),
      fallback_for_tools: list(get(meta, "fallback_for_tools")),
      channels: list(get(meta, "channels")),
      required_env: required_env(meta),
      required_commands: get(meta, "required_commands") |> list() |> Enum.filter(&command_name?/1),
      config_vars: config_vars(meta)
    }
  end

  @doc """
  Look a key up: `metadata.pepe.<key>`, then top level, then `metadata.<key>`. `nil` when
  absent everywhere.
  """
  @spec get(map(), String.t()) :: term()
  def get(meta, key) do
    metadata = if is_map(meta["metadata"]), do: meta["metadata"], else: %{}
    pepe = if is_map(metadata["pepe"]), do: metadata["pepe"], else: %{}

    first_present([pepe[key], meta[key], metadata[key]])
  end

  defp first_present(values), do: Enum.find(values, &(&1 not in [nil, "", []]))

  defp string(nil), do: nil
  defp string(value) when is_binary(value), do: value |> String.trim() |> String.trim("\"'") |> presence()
  defp string(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp string(_value), do: nil

  defp presence(""), do: nil
  defp presence(value), do: value

  # `a, b`, `[a, b]` and a real list all mean the same list.
  defp list(nil), do: []
  defp list(values) when is_list(values), do: values |> Enum.map(&string/1) |> Enum.reject(&is_nil/1)

  defp list(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp list(value), do: list(to_string(value))

  # `allowed-tools` is a space-delimited string in the spec.
  defp words(nil), do: []
  defp words(values) when is_list(values), do: list(values)
  defp words(value) when is_binary(value), do: value |> String.split(~r/[\s,]+/, trim: true)
  defp words(_value), do: []

  @env_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  # An executable name or a relative path to one - letters, digits, `_-./`. `required_commands`
  # is free text from a skill's own frontmatter, and every entry that survives here is later
  # interpolated into the skills index and into a `<system-reminder>` block a missing one
  # produces (`Pepe.Skills.Readiness`), so this is the same "not text, a name" boundary
  # `@env_name` already draws for a variable, just permissive enough for `docker-compose`,
  # `git-lfs` and `./scripts/setup.sh`.
  @command_name ~r{^[\w./-]+$}

  # `required_environment_variables`, `setup.collect_secrets` and the legacy
  # `prerequisites.env_vars` all mean "this skill needs these variables"; merged, deduped,
  # first entry wins.
  defp required_env(meta) do
    setup = if is_map(meta["setup"]), do: meta["setup"], else: %{}
    prereq = if is_map(meta["prerequisites"]), do: meta["prerequisites"], else: %{}
    setup_help = string(setup["help"])

    entries =
      Enum.map(as_list(get(meta, "required_environment_variables")), &env_entry/1) ++
        Enum.map(as_list(setup["collect_secrets"]), &secret_entry/1) ++
        Enum.map(as_list(prereq["env_vars"]), &env_entry/1)

    entries
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.name)
    |> Enum.map(fn entry -> if entry.help, do: entry, else: %{entry | help: setup_help} end)
  end

  defp as_list(nil), do: []
  defp as_list(value) when is_list(value), do: value
  defp as_list(value), do: [value]

  defp env_entry(name) when is_binary(name), do: env(%{"name" => name})
  defp env_entry(%{} = entry), do: env(entry)
  defp env_entry(_other), do: nil

  defp secret_entry(%{} = entry),
    do: env(%{"name" => entry["env_var"], "prompt" => entry["prompt"], "help" => entry["provider_url"] || entry["url"]})

  defp secret_entry(_other), do: nil

  defp env(entry) do
    name = string(entry["name"] || entry["env_var"])

    if is_binary(name) and Regex.match?(@env_name, name) do
      %{
        name: name,
        help: string(entry["help"] || entry["url"]),
        optional: entry["optional"] == true,
        required_for: string(entry["required_for"])
      }
    end
  end

  defp command_name?(name), do: Regex.match?(@command_name, name)

  # `metadata.pepe.config`: values an operator sets once, injected when the skill loads.
  defp config_vars(meta) do
    meta
    |> get("config")
    |> as_list()
    |> Enum.flat_map(fn
      %{"key" => key, "description" => description} = item when is_binary(key) and is_binary(description) ->
        [%{key: String.trim(key), description: String.trim(description), default: item["default"]}]

      _other ->
        []
    end)
    |> Enum.reject(&(&1.key == ""))
    |> Enum.uniq_by(& &1.key)
  end
end
