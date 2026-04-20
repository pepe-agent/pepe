defmodule PepeWeb.DashData do
  @moduledoc """
  Data/format helpers shared by the dashboard's per-section LiveViews - scope
  filtering, name qualification, form parsing and small display helpers. Kept in one
  place so each section LiveView (AgentsLive, ModelsLive, ...) can `import` them instead
  of each carrying its own copy.
  """
  use Gettext, backend: Pepe.Gettext

  alias Pepe.Company
  alias Pepe.Config
  alias Pepe.Webhooks

  ## channel/webhook providers

  @doc """
  Build the `%{name, label, schema}` cards for the given provider names, keeping only
  those that declare a `config_schema/0` (i.e. can be configured from the dashboard).
  """
  def webhook_provider_cards(names) do
    names
    |> Enum.map(fn name -> {name, Webhooks.provider(name)} end)
    |> Enum.filter(fn {_name, mod} -> mod && exports?(mod, :config_schema, 0) end)
    |> Enum.map(fn {name, mod} ->
      %{name: name, label: provider_label(mod, name), schema: mod.config_schema()}
    end)
  end

  # function_exported?/3 is false for a not-yet-loaded module; load it first.
  defp exports?(mod, fun, arity), do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)

  @doc "The native channels: built-in webhook providers (WhatsApp, Slack, Discord, Teams, Google Chat)."
  def native_channel_cards do
    Webhooks.providers()
    |> Enum.filter(&Webhooks.builtin?/1)
    |> webhook_provider_cards()
  end

  @doc "Installed plugin channel providers (everything that is not a built-in channel)."
  def plugin_channel_cards do
    Webhooks.providers()
    |> Enum.reject(&Webhooks.builtin?/1)
    |> webhook_provider_cards()
  end

  defp provider_label(mod, name),
    do: if(exports?(mod, :label, 0), do: mod.label(), else: name)

  ## scope filtering

  @doc "Is an item (by its agent/model handle) inside the selected scope?"
  def in_scope?(_handle, "all"), do: true
  def in_scope?(handle, "root"), do: Company.of(to_string(handle)) == nil
  def in_scope?(handle, company), do: Company.of(to_string(handle)) == company

  def scoped_agents(agents, scope), do: Enum.filter(agents, &in_scope?(&1.name, scope))
  def scoped_models(models, scope), do: Enum.filter(models, &in_scope?(&1.name, scope))
  def scoped_by_agent(list, scope, get), do: Enum.filter(list, &in_scope?(get.(&1), scope))

  def scoped_agent_names(scope) do
    Config.agents()
    |> Enum.filter(&in_scope?(&1.name, scope))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  def agent_names, do: Config.agents() |> Enum.map(& &1.name) |> Enum.sort()

  def agents_title("all"), do: gettext("Agents")
  def agents_title("root"), do: gettext("Agents · Principal")
  def agents_title(company), do: gettext("Agents · %{c}", c: company)
  def model_names, do: Config.models() |> Enum.map(& &1.name) |> Enum.sort()

  @doc "Qualify a bare name into the selected company scope (leave root/all/qualified as-is)."
  def scope_name("", _scope), do: ""

  def scope_name(name, scope) when scope not in [nil, "all", "root"] do
    if Company.of(name), do: name, else: Company.handle(scope, name)
  end

  def scope_name(name, _scope), do: name

  ## small parsing / blanks

  def blank(nil), do: nil
  def blank(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  def blank(v), do: v

  def reject_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)
  def put_or_delete(map, key, nil), do: Map.delete(map, key)
  def put_or_delete(map, key, value), do: Map.put(map, key, value)

  @doc "Comma text -> trimmed list (\"\" -> [])."
  def parse_list(nil), do: []

  def parse_list(str),
    do: str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  @doc "can_manage: \"\" -> nil (self), \"none\" -> [], \"*\" -> [\"*\"], \"a,b\" -> [a, b]."
  def parse_manage(v) do
    case blank(v) do
      nil -> nil
      "none" -> []
      "*" -> ["*"]
      str -> parse_list(str)
    end
  end

  def manages_text([]), do: gettext("nobody")
  def manages_text(["*"]), do: gettext("all agents")
  def manages_text(list) when is_list(list), do: Enum.join(list, ", ")
  def manages_text(_), do: gettext("self")

  def manage_field(nil), do: ""
  def manage_field([]), do: "none"
  def manage_field(["*"]), do: "*"
  def manage_field(list) when is_list(list), do: Enum.join(list, ",")

  ## telegram / gateway

  def save_bot("default", bot), do: Config.put_telegram(bot)
  def save_bot(name, bot), do: Config.put_telegram_bot(name, bot)

  def bot_active?(bot), do: Pepe.Gateways.Telegram.bot_active?(bot)

  def token_hint(nil), do: gettext("(none)")
  def token_hint("${" <> _ = env), do: env
  def token_hint(t), do: String.slice(to_string(t), 0, 6) <> "..."

  @doc "Apply bot changes to the running pollers (no-op if the supervisor isn't up)."
  def reload_gateways do
    Pepe.Gateways.Supervisor.reload_telegram()
  rescue
    _ -> :ok
  end

  ## cron / delivery

  def cron_next(cron) do
    case Pepe.Cron.next_run(cron) do
      nil -> "-"
      dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M %Z")
    end
  end

  def cron_history(id), do: Pepe.Cron.Log.tail(id, 3)
  def model_suffix(nil), do: ""
  def model_suffix(model), do: " · #{model}"

  def deliver_label("none"), do: gettext("Not sent")
  def deliver_label("telegram:" <> id), do: "Telegram #{id}"
  def deliver_label(other), do: other

  @doc "A manually-typed Telegram chat id wins over the dropdown; else use the select."
  def deliver_from(params) do
    case blank(params["deliver_chat"]) do
      nil -> blank(params["deliver"]) || "none"
      "telegram:" <> _ = full -> full
      chat -> "telegram:" <> chat
    end
  end

  def deliver_targets(sessions) do
    sessions
    |> Enum.map(& &1.key)
    |> Enum.filter(&String.starts_with?(&1, "telegram:"))
    |> Enum.uniq()
  end

  @doc "A readable, unique cron id derived from its name (append -2, -3, ... on collision)."
  def new_cron_id(name) do
    base =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> then(fn s -> if s == "", do: "task", else: s end)

    taken = Enum.map(Config.crons(), & &1.id)

    if base in taken do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(&suffixed_cron_id(base, &1, taken))
    else
      base
    end
  end

  defp suffixed_cron_id(base, n, taken) do
    candidate = "#{base}-#{n}"
    if candidate not in taken, do: candidate
  end

  ## models / providers / misc

  def provider_options, do: Enum.map(Pepe.Providers.all(), &{&1.key, &1.label})

  @common_timezones ~w(
    America/Sao_Paulo America/New_York America/Chicago America/Los_Angeles
    America/Mexico_City America/Argentina/Buenos_Aires America/Bogota
    Europe/London Europe/Lisbon Europe/Madrid Europe/Berlin Europe/Paris
    Africa/Johannesburg Asia/Dubai Asia/Kolkata Asia/Shanghai Asia/Tokyo
    Australia/Sydney Etc/UTC
  )

  def timezone_options do
    [Config.default_timezone() | @common_timezones] |> Enum.uniq()
  end

  def key_status(env) do
    if System.get_env(env),
      do: gettext("✓ it's set."),
      else: gettext("⚠ not set yet. Export it before use.")
  end

  def watch_origin_label(%{"channel" => "telegram"}), do: "telegram"
  def watch_origin_label(%{"channel" => ch}), do: ch
  def watch_origin_label(_), do: "log"

  def learn_icon(:skill), do: "🧠"
  def learn_icon(_memory), do: "📝"

  def learn_date(0), do: "-"
  def learn_date(ts), do: local_datetime(ts)

  @doc """
  Format a unix timestamp in the operator's configured timezone (from `mix pepe setup`,
  falling back to UTC), so the dashboard shows local time, not UTC.
  """
  def local_datetime(ts, fmt \\ "%Y-%m-%d %H:%M")

  def local_datetime(ts, fmt) when is_integer(ts) do
    with {:ok, utc} <- DateTime.from_unix(ts),
         {:ok, dt} <- DateTime.shift_zone(utc, Config.default_timezone()) do
      Calendar.strftime(dt, fmt)
    else
      _ -> "-"
    end
  end

  def local_datetime(_ts, _fmt), do: "-"

  @doc "Known Telegram chat targets (from persisted sessions), for the cron delivery field."
  def telegram_targets do
    Pepe.Agent.SessionPersistence.all()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&String.starts_with?(&1, "telegram:"))
    |> Enum.uniq()
  end

  ## shared sidebar events - the workspace scope drives agents/models, so changing it
  ## (or creating a company) jumps to that scope's Agents page.

  def set_scope(socket, %{"scope" => scope}, base) do
    Phoenix.LiveView.push_navigate(socket, to: "#{base}?scope=#{scope}")
  end

  def add_company(socket, %{"name" => name}) do
    name = String.trim(name)

    case Config.add_company(name) do
      :ok ->
        Phoenix.LiveView.push_navigate(socket, to: "/agents?scope=#{name}")

      _ ->
        Phoenix.LiveView.put_flash(socket, :error, gettext("Invalid or duplicate company name."))
    end
  end

  ## usage / billing display

  @doc "Human granularity options for the usage cycle selector."
  def granularity_options do
    [
      {"hour", gettext("Hour")},
      {"day", gettext("Day")},
      {"week", gettext("Week")},
      {"month", gettext("Month")},
      {"year", gettext("Year")}
    ]
  end

  @currency_symbols %{"USD" => "$", "BRL" => "R$", "EUR" => "€", "GBP" => "£"}

  @doc "Format money in the operator's currency, e.g. `$13.55` or `R$ 226.80`."
  def money(amount, currency) when is_number(amount) do
    n = :erlang.float_to_binary(amount / 1, decimals: 2)

    case @currency_symbols[currency] do
      nil -> "#{currency} #{n}"
      "$" -> "$#{n}"
      sym -> "#{sym} #{n}"
    end
  end

  def money(_amount, currency), do: money(0.0, currency)

  @doc "Compact token count: 812 · 12.3K · 4.5M."
  def tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{:erlang.float_to_binary(n / 1_000_000, decimals: 1)}M"

  def tokens(n) when is_integer(n) and n >= 1_000,
    do: "#{:erlang.float_to_binary(n / 1_000, decimals: 1)}K"

  def tokens(n) when is_integer(n), do: Integer.to_string(n)
  def tokens(_), do: "0"

  @doc "A short label for how fresh the live price cache is."
  def price_cache_label(nil), do: gettext("Using built-in seed prices (never refreshed)")

  def price_cache_label(%{fetched_at: at, count: count}) do
    gettext("%{count} live prices · refreshed %{date}", count: count, date: local_datetime(at))
  end
end
