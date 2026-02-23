defmodule Pepe.HooksTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Hooks
  alias Pepe.Hooks.PII.Recognizers

  # A valid example CPF (checksum passes) and CNPJ for the tests.
  @cpf "529.982.247-25"
  @cnpj "11.222.333/0001-81"

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_hooks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  describe "recognizers" do
    test "checksum validators accept valid ids and reject bogus ones" do
      assert Recognizers.cpf?(@cpf)
      refute Recognizers.cpf?("123.456.789-00")
      refute Recognizers.cpf?("000.000.000-00")

      assert Recognizers.cnpj?(@cnpj)
      refute Recognizers.cnpj?("11.222.333/0001-99")

      assert Recognizers.luhn?("4111 1111 1111 1111")
      refute Recognizers.luhn?("4111 1111 1111 1112")
    end

    test "resolve expands packs and compiles custom patterns" do
      recs =
        Recognizers.resolve(%{
          "packs" => ["br"],
          "custom" => [%{"name" => "apol", "pattern" => "APOL-\\d{4}"}]
        })

      names = Enum.map(recs, & &1.name)
      assert "cpf" in names and "cnpj" in names and "apol" in names
    end

    test "an invalid custom pattern is dropped, and valid_pattern?/1 reports it" do
      refute Recognizers.valid_pattern?("([unclosed")
      assert Recognizers.valid_pattern?("APOL-\\d+")
      assert Recognizers.resolve(%{"custom" => [%{"name" => "bad", "pattern" => "([oops"}]}) == []
    end
  end

  describe "pii_redact hook + pipeline" do
    setup do
      Config.put_hook_settings("pii_redact", %{"packs" => ["br", "intl"]})
      agent = %Agent{name: "acme/support", hooks: ["pii_redact"]}
      {:ok, agent: agent}
    end

    test "redacts structured PII and restores it on the way out", %{agent: agent} do
      text = "Meu CPF é #{@cpf} e email john@acme.com"
      {redacted, entries} = Hooks.transform(:inbound, text, agent)

      # the real values are gone; tokens took their place
      refute redacted =~ @cpf
      refute redacted =~ "john@acme.com"
      assert redacted =~ "[CPF_1]"
      assert redacted =~ "[EMAIL_1]"

      # a reply that uses the tokens is restored to the real values for the user
      restored = Hooks.restore("Confirmado o [CPF_1] e o [EMAIL_1].", entries)
      assert restored == "Confirmado o #{@cpf} e o john@acme.com."
    end

    test "an invalid CPF is left untouched (checksum guard)", %{agent: agent} do
      {redacted, entries} = Hooks.transform(:inbound, "CPF 123.456.789-00", agent)
      assert redacted == "CPF 123.456.789-00"
      assert entries == []
    end

    test "reversible: false tokenizes but keeps no restore map" do
      Config.put_hook_settings("pii_redact", %{"packs" => ["br"], "reversible" => false})
      agent = %Agent{name: "acme/support", hooks: ["pii_redact"]}

      {redacted, entries} = Hooks.transform(:inbound, "CPF #{@cpf}", agent)
      assert redacted =~ "[CPF_1]"
      assert entries == []
    end

    test "an agent with no hooks passes text through unchanged" do
      agent = %Agent{name: "assistant", hooks: []}
      assert {"CPF #{@cpf}", []} == Hooks.transform(:inbound, "CPF #{@cpf}", agent)
      refute Hooks.any?(agent)
    end

    test "a company default_hook applies to its agents" do
      Config.add_company("acme", %{"default_hooks" => ["pii_redact"]})
      agent = %Agent{name: "acme/sales", hooks: []}

      {redacted, _} = Hooks.transform(:inbound, "CPF #{@cpf}", agent)
      assert redacted =~ "[CPF_1]"
    end
  end

  describe "http_redact hook" do
    test "posts the message and uses the endpoint's transformed response" do
      Mimic.stub(Req, :post, fn _url, opts ->
        body = opts[:json]
        assert body["stage"] == "inbound"
        assert body["text"] == "CPF 999"

        {:ok,
         %{
           status: 200,
           body: %{"text" => "CPF [X]", "map" => [%{"fake" => "[X]", "real" => "999"}]}
         }}
      end)

      Config.put_hook_settings("http_redact", %{"url" => "https://redactor.example/r"})
      agent = %Agent{name: "acme/support", hooks: ["http_redact"]}

      {redacted, entries} = Hooks.transform(:inbound, "CPF 999", agent)
      assert redacted == "CPF [X]"
      assert [%{"fake" => "[X]", "real" => "999"}] = entries
      assert Hooks.restore("check [X]", entries) == "check 999"
    end

    test "falls back to the original text when the endpoint errors" do
      Mimic.stub(Req, :post, fn _url, _opts -> {:error, :econnrefused} end)
      Config.put_hook_settings("http_redact", %{"url" => "https://x"})
      agent = %Agent{name: "acme/support", hooks: ["http_redact"]}

      assert {"CPF 999", []} = Hooks.transform(:inbound, "CPF 999", agent)
    end
  end

  describe "config generator" do
    test "builds a validated pii_redact config and drops invalid custom patterns" do
      Config.put_model(%Pepe.Config.Model{name: "local", model: "m"})

      content =
        Jason.encode!(%{
          "packs" => ["br"],
          "recognizers" => ["email"],
          "custom" => [
            %{"name" => "policy", "pattern" => "APOL-\\d+", "replace" => "[POLICY]"},
            %{"name" => "bad", "pattern" => "([oops", "replace" => "[X]"}
          ]
        })

      Mimic.stub(Pepe.LLM, :chat, fn _model, _msgs, _opts -> {:ok, %{content: content}} end)

      assert {:ok, config, dropped} =
               Pepe.Hooks.Generator.generate("cpf, cnpj and our policy numbers", "local")

      assert config["packs"] == ["br"]
      assert config["recognizers"] == ["email"]
      assert [%{"name" => "policy"}] = config["custom"]
      assert "custom:bad" in dropped
    end
  end

  describe "require_redaction trava" do
    test "the runtime refuses a require_redaction model when the agent has no hook" do
      model = %Pepe.Config.Model{
        name: "openai",
        model: "gpt",
        base_url: "http://localhost:1",
        api_key: "k",
        require_redaction: true
      }

      no_hook = %Agent{name: "a", hooks: []}
      assert {:error, :redaction_required} = Pepe.Agent.Runtime.run(no_hook, [], model: model)

      # with a redaction hook the guard is satisfied (Hooks.any?/1 is what it checks)
      assert Hooks.any?(%Agent{name: "a", hooks: ["pii_redact"]})
    end
  end
end
