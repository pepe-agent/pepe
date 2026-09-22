defmodule Pepe.Skills.Snapshot do
  @moduledoc """
  Moves a set of installed skills, and how they are switched, from one Pepe to another.

  A snapshot is a JSON file listing every marketplace-installed skill (its name, where it came
  from and the hash of what was installed) plus the settings that describe *what the operator
  wants*: which skills are disabled (everywhere or per channel), which are auto-loaded, the
  template-variable switch and the values set for skill-declared settings.

  It deliberately does not carry what is a decision about one machine and one person:

    * **Trust.** A snapshot can name `official`; that is a claim in a file, so it is never
      believed. Each skill is installed again, resolved against this machine's registries, and
      takes the trust level that resolution gives it (a source that does not resolve is
      `community`). Every install goes through the same Sentinel scan as any other.
    * **Inline shell** stays off unless this operator turns it on here.
    * **Directories** (external skill directories, trusted repositories) are paths on the
      machine that made the snapshot.
  """

  alias Pepe.Config
  alias Pepe.Skills.Marketplace
  alias Pepe.Skills.Settings

  @format "pepe-skills-snapshot"
  @version 1

  @type restored :: %{installed: [String.t()], skipped: [String.t()], failed: [{String.t(), term()}], settings: [String.t()]}

  @doc "Write the snapshot to `path`. Returns the number of skills in it."
  @spec export(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def export(path) do
    skills =
      for {name, meta} <- Enum.sort(Config.installed_skills()) do
        %{"name" => name, "source" => meta["source"], "hash" => meta["hash"], "trust_level" => meta["trust_level"]}
      end

    body = %{
      "format" => @format,
      "version" => @version,
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "skills" => skills,
      "settings" => portable_settings()
    }

    with :ok <- File.write(path, Jason.encode!(body, pretty: true) <> "\n"), do: {:ok, length(skills)}
  end

  @doc """
  Install what the snapshot at `path` lists and apply its portable settings. Options:
  `:force` (install past a `:danger` verdict, as for `mix pepe skill install --force`) and
  `:settings` (`false` to skip the settings). A skill already installed from the same source
  with the same hash is skipped.
  """
  @spec restore(String.t(), keyword()) :: {:ok, restored()} | {:error, :not_a_snapshot | :unreadable | {:unsupported_version, term()}}
  def restore(path, opts \\ []) do
    with {:ok, text} <- read(path),
         {:ok, %{"format" => @format, "version" => version} = body} <- decode(text),
         :ok <- supported(version) do
      results = Enum.map(list(body["skills"]), &install(&1, opts[:force] == true))

      {:ok,
       %{
         installed: for({:installed, name} <- results, do: name),
         skipped: for({:skipped, name} <- results, do: name),
         failed: for({:failed, name, reason} <- results, do: {name, reason}),
         settings: if(opts[:settings] == false, do: [], else: apply_settings(body["settings"]))
       }}
    else
      {:ok, _other} -> {:error, :not_a_snapshot}
      {:error, :not_a_snapshot} -> {:error, :not_a_snapshot}
      {:error, {:unsupported_version, _} = unsupported} -> {:error, unsupported}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  # -- reading -----------------------------------------------------------------------------

  defp read(path), do: File.read(path)

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :not_a_snapshot}
    end
  end

  defp supported(@version), do: :ok
  defp supported(other), do: {:error, {:unsupported_version, other}}

  defp list(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list(_value), do: []

  # -- skills ------------------------------------------------------------------------------

  defp install(%{"name" => name, "source" => source} = entry, force?) when is_binary(name) and is_binary(source) do
    if unchanged?(name, source, entry["hash"]),
      do: {:skipped, name},
      else: name |> do_install(source, force?) |> outcome(name)
  end

  defp install(entry, _force?), do: {:failed, to_string(entry["name"]), :malformed_entry}

  defp unchanged?(name, source, hash) do
    match?(%{"source" => ^source, "hash" => ^hash}, Config.installed_skill(name)) and is_binary(hash)
  end

  # The name resolves to the very same source here: install it by name, so it earns whatever
  # trust this machine's registries give it. Otherwise the source is all there is to go on.
  defp do_install(name, source, force?) do
    case Marketplace.resolve(name) do
      {:ok, ^source, _trust} -> Marketplace.install(name, force: force?)
      _ -> Marketplace.install(name, source: source, force: force?)
    end
  end

  defp outcome({:ok, installed, _scan}, _name), do: {:installed, installed}
  defp outcome({:error, {:unsafe, _scan}}, name), do: {:failed, name, :unsafe}
  defp outcome({:error, reason}, name), do: {:failed, name, reason}

  # -- settings ----------------------------------------------------------------------------

  defp portable_settings do
    %{
      "disabled" => Settings.disabled(),
      "channel_disabled" => channel_disabled(),
      "auto_load" => Settings.auto_load(),
      "template_vars" => Settings.template_vars?(),
      "config" => Settings.config_values()
    }
  end

  defp channel_disabled do
    case Config.load()["skills"] do
      %{"channel_disabled" => %{} = map} -> map
      _ -> %{}
    end
  end

  defp apply_settings(%{} = settings) do
    [
      {"disabled", &apply_disabled/1},
      {"channel_disabled", &apply_channel_disabled/1},
      {"auto_load", &apply_auto_load/1},
      {"template_vars", &apply_template_vars/1},
      {"config", &apply_config/1}
    ]
    |> Enum.filter(fn {key, fun} -> Map.has_key?(settings, key) and fun.(settings[key]) == :applied end)
    |> Enum.map(&elem(&1, 0))
  end

  defp apply_settings(_other), do: []

  defp apply_disabled(names) when is_list(names), do: each_name(names, &Settings.disable(&1, nil))
  defp apply_disabled(_other), do: :ignored

  defp apply_channel_disabled(%{} = map) do
    for {channel, names} <- map, is_binary(channel), is_list(names), name <- names, is_binary(name), do: Settings.disable(name, channel)
    :applied
  end

  defp apply_channel_disabled(_other), do: :ignored

  defp apply_auto_load(names) when is_list(names), do: each_name(names, &Settings.add_auto_load/1)
  defp apply_auto_load(_other), do: :ignored

  defp apply_template_vars(value) when is_boolean(value), do: Settings.set_flag("template_vars", value) |> then(fn _ -> :applied end)
  defp apply_template_vars(_other), do: :ignored

  defp apply_config(%{} = map) do
    for {key, value} <- map, is_binary(key), do: Settings.put_config(key, value)
    :applied
  end

  defp apply_config(_other), do: :ignored

  defp each_name(names, fun) do
    for name <- names, is_binary(name), do: fun.(name)
    :applied
  end
end
