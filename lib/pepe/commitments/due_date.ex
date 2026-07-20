defmodule Pepe.Commitments.DueDate do
  @moduledoc """
  Resolves a commitment's raw `due_when` phrase (as returned by the extraction model,
  e.g. "amanhã", "Friday", "in 2 weeks") into a concrete unix timestamp - deterministically,
  with no LLM involved. The model is never trusted to compute a timestamp itself: it
  doesn't reliably know "now", and reproducing NL date math *inside* a prompt would just be
  a second parser to get wrong instead of one.

  Resolved against `from_at` (the triggering message's own timestamp, not extraction time,
  which can run slightly later - "tomorrow" said right before midnight must resolve
  against when it was said) and a timezone. A same-day weekday name ("sexta" said on a
  Friday) is genuine ambiguity between today and +7 days - this returns `nil` rather than
  guess, which is what forces a needs-review state upstream. Anything outside the small
  EN/PT/ES grammar below also returns `nil`.

  v1 limitation, stated rather than silently wrong: a phrase's *date* resolves correctly,
  but any time-of-day it carries ("tomorrow at 5pm") is not parsed - every resolution lands
  at a fixed 09:00 local. Worth revisiting if it turns out to matter in practice; not
  solved here to keep this module small and fully testable.
  """

  @default_hour 9

  @weekdays %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7,
    "segunda" => 1,
    "segunda-feira" => 1,
    "terça" => 2,
    "terca" => 2,
    "terça-feira" => 2,
    "terca-feira" => 2,
    "martes" => 2,
    "quarta" => 3,
    "quarta-feira" => 3,
    "miércoles" => 3,
    "miercoles" => 3,
    "quinta" => 4,
    "quinta-feira" => 4,
    "jueves" => 4,
    "sexta" => 5,
    "sexta-feira" => 5,
    "viernes" => 5,
    "sábado" => 6,
    "sabado" => 6,
    "domingo" => 7,
    "lunes" => 1
  }

  @next_prefixes ["next", "próxima", "proxima", "próximo", "proximo", "que vem", "que viene"]

  @doc """
  Resolves `due_when` to a unix timestamp, or `nil` when it's unresolvable or ambiguous.
  `from_at` is the message's own unix timestamp; `timezone` defaults to
  `Pepe.Config.default_timezone/0`.
  """
  @spec resolve(String.t() | nil, integer(), String.t() | nil) :: integer() | nil
  def resolve(due_when, from_at, timezone \\ nil)
  def resolve(nil, _from_at, _timezone), do: nil
  def resolve("", _from_at, _timezone), do: nil

  def resolve(due_when, from_at, timezone) do
    tz = timezone || Pepe.Config.default_timezone()

    with {:ok, utc} <- DateTime.from_unix(from_at),
         {:ok, now} <- DateTime.shift_zone(utc, tz) do
      due_when
      |> String.downcase()
      |> String.trim()
      |> resolve_base(DateTime.to_date(now))
      |> at_default_hour(tz)
    else
      _ -> nil
    end
  end

  defp resolve_base(phrase, today) do
    cond do
      phrase in ["today", "hoje", "hoy"] ->
        today

      phrase in ["tomorrow", "amanhã", "amanha", "mañana", "manana"] ->
        Date.add(today, 1)

      match = Regex.run(~r/^(?:in|em|en) (\d+) (?:days?|dias?|d[ií]as?)$/u, phrase) ->
        Date.add(today, String.to_integer(Enum.at(match, 1)))

      match = Regex.run(~r/^(?:in|em|en) (\d+) (?:weeks?|semanas?)$/u, phrase) ->
        Date.add(today, String.to_integer(Enum.at(match, 1)) * 7)

      true ->
        resolve_weekday(phrase, today)
    end
  end

  defp resolve_weekday(phrase, today) do
    {forced_next?, name} = strip_next_prefix(phrase)

    case @weekdays[name] do
      nil ->
        nil

      target ->
        diff = Integer.mod(target - Date.day_of_week(today), 7)

        cond do
          diff > 0 -> Date.add(today, diff)
          forced_next? -> Date.add(today, 7)
          true -> nil
        end
    end
  end

  defp strip_next_prefix(phrase) do
    Enum.find_value(@next_prefixes, fn prefix ->
      if String.starts_with?(phrase, prefix <> " "),
        do: {true, phrase |> String.trim_leading(prefix) |> String.trim()}
    end) || {false, phrase}
  end

  defp at_default_hour(nil, _tz), do: nil

  defp at_default_hour(date, tz) do
    case DateTime.new(date, Time.new!(@default_hour, 0, 0), tz) do
      {:ok, dt} -> DateTime.to_unix(dt)
      {:ambiguous, dt, _later} -> DateTime.to_unix(dt)
      {:gap, _before, dt} -> DateTime.to_unix(dt)
      {:error, _} -> nil
    end
  end
end
