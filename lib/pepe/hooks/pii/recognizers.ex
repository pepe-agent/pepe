defmodule Pepe.Hooks.PII.Recognizers do
  @moduledoc """
  The library of named PII recognizers for the regex redactor - universal ones
  (email, credit card, IP) plus per-country identifiers (Brazil today; more via
  packs and user-defined `custom` patterns). Each is a regex; the ones with a
  checksum (CPF, CNPJ, card) also validate, to cut false positives.

  Structured PII only. Names/addresses (unstructured, culture-specific) are the
  job of `llm_redact` / `presidio`.
  """

  @type recognizer :: %{
          name: String.t(),
          regex: Regex.t(),
          label: String.t(),
          validate: (String.t() -> boolean()) | nil
        }

  # name => {regex, LABEL, validator | nil}
  @builtin %{
    "email" => {~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, "EMAIL", nil},
    "ip" => {~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/, "IP", nil},
    "credit_card" => {~r/\b(?:\d[ -]*?){13,16}\b/, "CARD", :luhn},
    "cpf" => {~r/\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b/, "CPF", :cpf},
    "cnpj" => {~r|\b\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}\b|, "CNPJ", :cnpj},
    "cep" => {~r/\b\d{5}-?\d{3}\b/, "CEP", nil},
    "phone_br" => {~r/(?:\+?55\s?)?(?:\(?\d{2}\)?[\s-]?)?9?\d{4}[\s-]?\d{4}\b/, "PHONE", nil},
    "ssn_us" => {~r/\b\d{3}-\d{2}-\d{4}\b/, "SSN", nil},
    "phone_us" => {~r/(?:\+?1[\s-]?)?\(?\d{3}\)?[\s-]?\d{3}[\s-]?\d{4}\b/, "PHONE", nil}
  }

  @packs %{
    "intl" => ["email", "credit_card", "ip"],
    "br" => ["cpf", "cnpj", "cep", "phone_br"],
    "us" => ["ssn_us", "phone_us"]
  }

  @doc "The built-in recognizer names."
  def builtin_names, do: Map.keys(@builtin)

  @doc "The named packs (region bundles)."
  def packs, do: @packs

  @doc """
  Resolve a `pii_redact` settings map into the active recognizer list: expand
  `packs`, add explicit `recognizers`, and compile any `custom` `{name, pattern,
  replace}`. Longest label first isn't needed; matching handles overlap.
  """
  @spec resolve(map()) :: [recognizer()]
  def resolve(settings) do
    from_packs = settings |> Map.get("packs", []) |> Enum.flat_map(&Map.get(@packs, &1, []))
    names = (from_packs ++ Map.get(settings, "recognizers", [])) |> Enum.uniq()

    builtin = Enum.flat_map(names, &builtin(&1))
    custom = settings |> Map.get("custom", []) |> Enum.flat_map(&custom(&1))
    builtin ++ custom
  end

  defp builtin(name) do
    case Map.get(@builtin, name) do
      {regex, label, validator} ->
        [%{name: name, regex: regex, label: label, validate: validator_fun(validator)}]

      nil ->
        []
    end
  end

  defp custom(%{"name" => name, "pattern" => pattern} = c) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        label = c["replace"] || "[#{String.upcase(name)}]"
        [%{name: name, regex: regex, label: strip_brackets(label), validate: nil}]

      _ ->
        []
    end
  end

  defp custom(_), do: []

  @doc "Compile-check a custom pattern (backend validation before saving)."
  def valid_pattern?(pattern) when is_binary(pattern),
    do: match?({:ok, _}, Regex.compile(pattern))

  def valid_pattern?(_), do: false

  defp strip_brackets(label), do: label |> String.trim_leading("[") |> String.trim_trailing("]")

  ## validators

  defp validator_fun(:luhn), do: &luhn?/1
  defp validator_fun(:cpf), do: &cpf?/1
  defp validator_fun(:cnpj), do: &cnpj?/1
  defp validator_fun(nil), do: nil

  defp digits(s),
    do: s |> String.replace(~r/\D/, "") |> String.graphemes() |> Enum.map(&String.to_integer/1)

  def luhn?(s) do
    ds = digits(s)

    if length(ds) < 13 do
      false
    else
      ds
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {d, i} -> if rem(i, 2) == 1, do: double(d), else: d end)
      |> Enum.sum()
      |> rem(10) == 0
    end
  end

  defp double(d), do: (d * 2) |> then(&if(&1 > 9, do: &1 - 9, else: &1))

  def cpf?(s) do
    ds = digits(s)
    length(ds) == 11 and not all_same?(ds) and check_digit(ds, 9, 10) and check_digit(ds, 10, 11)
  end

  def cnpj?(s) do
    ds = digits(s)
    w1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
    w2 = [6 | w1]
    length(ds) == 14 and not all_same?(ds) and cnpj_digit(ds, w1, 12) and cnpj_digit(ds, w2, 13)
  end

  defp all_same?([h | t]), do: Enum.all?(t, &(&1 == h))

  defp check_digit(ds, take, pos) do
    sum =
      ds
      |> Enum.take(take)
      |> Enum.with_index()
      |> Enum.map(fn {d, i} -> d * (take + 1 - i) end)
      |> Enum.sum()

    r = rem(sum * 10, 11)
    Enum.at(ds, pos - 1) == if(r == 10, do: 0, else: r)
  end

  defp cnpj_digit(ds, weights, pos) do
    sum =
      ds
      |> Enum.take(length(weights))
      |> Enum.zip(weights)
      |> Enum.map(fn {d, w} -> d * w end)
      |> Enum.sum()

    r = rem(sum, 11)
    Enum.at(ds, pos) == if(r < 2, do: 0, else: 11 - r)
  end
end
