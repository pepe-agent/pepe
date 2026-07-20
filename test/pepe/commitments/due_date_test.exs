defmodule Pepe.Commitments.DueDateTest do
  use ExUnit.Case, async: true

  alias Pepe.Commitments.DueDate

  # Wednesday 2026-07-22, 10:00 America/Sao_Paulo (UTC-3).
  @from_at 1_784_725_200
  @tz "America/Sao_Paulo"

  defp resolve(phrase), do: DueDate.resolve(phrase, @from_at, @tz)

  test "nil/blank input resolves to nil" do
    assert DueDate.resolve(nil, @from_at, @tz) == nil
    assert DueDate.resolve("", @from_at, @tz) == nil
  end

  test "today/hoje/hoy resolve to the same calendar day at 09:00 local" do
    assert resolve("today") == 1_784_721_600
    assert resolve("hoje") == 1_784_721_600
    assert resolve("hoy") == 1_784_721_600
  end

  test "tomorrow/amanhã/mañana resolve to the next calendar day" do
    assert resolve("tomorrow") == 1_784_808_000
    assert resolve("amanhã") == 1_784_808_000
    assert resolve("mañana") == 1_784_808_000
  end

  test "a future weekday this week resolves to its next occurrence" do
    # Wednesday -> Friday is +2 days.
    assert resolve("friday") == 1_784_894_400
    assert resolve("sexta") == 1_784_894_400
    assert resolve("viernes") == 1_784_894_400
  end

  test "a weekday earlier in the week rolls over to next week" do
    # Wednesday -> Monday is +5 days (this Monday already passed).
    assert resolve("monday") == 1_785_153_600
    assert resolve("segunda") == 1_785_153_600
  end

  test "the same weekday as today, with no 'next' qualifier, is ambiguous" do
    assert resolve("wednesday") == nil
    assert resolve("quarta") == nil
  end

  test "'next <same weekday>' resolves unambiguously to +7 days" do
    assert resolve("next wednesday") == 1_785_326_400
    assert resolve("próxima quarta") == 1_785_326_400
  end

  test "in N days / em N dias / en N días" do
    assert resolve("in 3 days") == 1_784_980_800
    assert resolve("em 3 dias") == 1_784_980_800
    assert resolve("en 3 días") == 1_784_980_800
  end

  test "in N weeks / em N semanas" do
    assert resolve("in 2 weeks") == 1_785_931_200
    assert resolve("em 2 semanas") == 1_785_931_200
  end

  test "case and surrounding whitespace don't matter" do
    assert resolve("  Tomorrow  ") == 1_784_808_000
  end

  test "anything outside the grammar resolves to nil" do
    assert resolve("next quarter") == nil
    assert resolve("sometime soon") == nil
    assert resolve("eventually") == nil
  end

  test "resolves against the message's own timestamp, not any other 'now'" do
    # A different from_at (one week later, still a Wednesday) shifts "tomorrow" with it.
    later = @from_at + 7 * 86_400
    assert DueDate.resolve("tomorrow", later, @tz) == 1_784_808_000 + 7 * 86_400
  end

  test "defaults to Pepe.Config.default_timezone/0 when no timezone is passed" do
    assert DueDate.resolve("tomorrow", @from_at) == DueDate.resolve("tomorrow", @from_at, Pepe.Config.default_timezone())
  end
end
