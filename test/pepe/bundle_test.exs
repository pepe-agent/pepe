defmodule Pepe.BundleTest do
  @moduledoc """
  Lifting one company out of a shared install and standing it up on its own.

  The thing worth pinning is the de-scoping. A company's rows are threaded through the shared
  `config.json` as `company/agent` handles, so you cannot get a working single-tenant install by
  copying a folder. Extract rewrites those handles to bare root names, carries only that
  company's agents/models/workspaces/usage (never another tenant's), and pulls in any shared
  model a kept agent leans on so the bundle works on an empty box.
  """
  use ExUnit.Case, async: false

  alias Pepe.Bundle
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Cron
  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_bundle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  # Two companies plus a shared root model, so isolation and the shared-dependency pull-in both
  # have something to prove.
  defp seed_two_companies do
    Config.add_company("acme")
    Config.add_company("globex")

    # A root/shared model (bare name = root scope) that an acme agent will depend on.
    Config.put_model(%Model{name: "shared-gpt", base_url: "https://x/v1", api_key: "${SHARED_KEY}", model: "g"})

    Config.put_model(%Model{name: "acme/gpt", base_url: "https://x/v1", api_key: "${ACME_KEY}", model: "g"})
    Config.put_model(%Model{name: "globex/gpt", base_url: "https://x/v1", api_key: "${GLOBEX_KEY}", model: "g"})

    Config.put_agent(%Agent{name: "acme/sales", model: "acme/gpt", system_prompt: "sell", can_message: ["acme/support"]})
    Config.put_agent(%Agent{name: "acme/support", model: "shared-gpt", system_prompt: "help"})
    Config.put_agent(%Agent{name: "globex/bot", model: "globex/gpt", system_prompt: "hi"})

    Config.put_cron(%Cron{id: "c1", agent: "acme/sales", prompt: "morning", schedule: "0 8 * * *"})
    Config.add_api_token(company: "acme", agent: "acme/sales", label: "acme key")
    Config.set_default_model_for("acme", "acme/gpt")

    # On-disk state that must travel: agent workspaces, the company shared space, the ledger.
    for name <- ~w(sales support) do
      dir = Path.join([Config.home(), "companies", "acme", "agents", name])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SOUL.md"), "I am #{name}")
    end

    File.mkdir_p!(Path.join([Config.home(), "companies", "acme", "shared"]))
    File.write!(Path.join([Config.home(), "companies", "acme", "shared", "notes.md"]), "shared acme note")

    usage = Path.join([Config.home(), "data", "usage", "acme"])
    File.mkdir_p!(usage)
    File.write!(Path.join(usage, "2026-07.jsonl"), ~s({"at":1720000000,"agent":"acme/sales","model":"g","in":10,"out":5}\n))
  end

  describe "Config.extract_config/1" do
    test "de-scopes only the named company, pulling in its shared model dependency" do
      seed_two_companies()

      assert {:ok, config, report} = Config.extract_config("acme")

      # Handles are bare now, and they are acme's, not globex's.
      assert Map.keys(config["agents"]) |> Enum.sort() == ["sales", "support"]
      refute Map.has_key?(config, "companies")

      # can_message was re-scoped along with the keys.
      assert config["agents"]["sales"]["can_message"] == ["support"]

      # The models: acme's own, de-scoped, plus the shared root model support depends on.
      names = config["models"] |> Map.values() |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["gpt", "shared-gpt"]
      assert report.shared_models == ["shared-gpt"]

      # The cron bound to acme/sales came along and points at the bare handle.
      assert [%{"agent" => "sales"}] = Map.values(config["crons"])

      # The API token de-scopes to the ROOT scope, which is `nil` (not `""`), and its agent
      # binding goes bare - otherwise the restored token would match no agent.
      assert [%{"company" => tcompany, "agent" => "sales"}] = Map.values(config["api_tokens"])
      assert tcompany == nil

      # Only acme's secrets are referenced; globex's key is gone with globex.
      assert report.secrets == ["ACME_KEY", "SHARED_KEY"]
      refute "GLOBEX_KEY" in report.secrets
    end

    test "an unknown company is refused" do
      assert Config.extract_config("nope") == {:error, :not_found}
    end

    test "the secrets report includes vault-opening credentials, not only ${VAR} refs" do
      seed_two_companies()
      # A vault-based setup: the model's key is fetched by a command, and the resolver needs
      # OP_TOKEN to run it. That name never appears as ${VAR}, so a plain scan would miss it and
      # the operator would stand up a new server whose vaults cannot open.
      Config.save(Map.put(Config.load(), "secrets", %{"vault_env" => ["OP_TOKEN"]}))

      assert {:ok, _config, report} = Config.extract_config("acme")
      assert "OP_TOKEN" in report.secrets
      # The ${VAR} refs are still there too.
      assert "ACME_KEY" in report.secrets
    end

    test "a cross-company model reference is not leaked into the bundle" do
      seed_two_companies()

      # A misconfiguration: an acme agent points at globex's model (by id, the way agents store
      # models). Extracting acme must NOT pull globex's connection - base_url, headers, the name
      # of its secret - into acme's archive. The reference is dropped (fails closed) rather than
      # carrying another tenant's credentials.
      Config.put_agent(%Agent{name: "acme/stray", model: "globex/gpt", system_prompt: "x"})

      assert {:ok, config, report} = Config.extract_config("acme")

      names = config["models"] |> Map.values() |> Enum.map(& &1["name"]) |> Enum.sort()
      refute "globex/gpt" in names
      refute "GLOBEX_KEY" in report.secrets
      # The intended shared-model pull-in still works: root models are carried.
      assert "shared-gpt" in names
    end
  end

  describe "extract carries the whole company, and only that company" do
    test "a webhook of another company is not leaked; the company's own travels de-scoped" do
      seed_two_companies()

      Config.put_webhook("acme-wa", %{
        "provider" => "whatsapp",
        "company" => "acme",
        "agent" => "acme/sales",
        "config" => %{"access_token" => "${ACME_WA_TOKEN}"}
      })

      Config.put_webhook("globex-wa", %{
        "provider" => "whatsapp",
        "company" => "globex",
        "agent" => "globex/bot",
        "config" => %{"access_token" => "globex-secret-literal"}
      })

      assert {:ok, config, report} = Config.extract_config("acme")

      # globex's webhook - and its literal token - never enter acme's bundle.
      assert Map.keys(config["webhooks"]) == ["acme-wa"]
      refute Jason.encode!(config) =~ "globex-secret-literal"

      # acme's own webhook travels, de-scoped to the root scope (company nil, agent bare).
      assert %{"company" => nil, "agent" => "sales"} = config["webhooks"]["acme-wa"]
      assert "ACME_WA_TOKEN" in report.secrets
    end

    test "a company-scoped API token (no agent) is kept, not dropped" do
      seed_two_companies()
      # `token add --company acme` with no agent: scoped by the company field alone. This is the
      # commonest token shape for a whole tenant, and filtering by agent would silently drop it.
      Config.add_api_token(company: "acme", label: "tenant key")

      assert {:ok, config, _report} = Config.extract_config("acme")

      companies = config["api_tokens"] |> Map.values() |> Enum.map(& &1["company"]) |> Enum.uniq()
      assert companies == [nil]
      # Both the agent-bound token (from the seed) and the company-only one survived.
      assert map_size(config["api_tokens"]) == 2
    end

    test "the company's billing becomes root; the source install's root billing is not carried" do
      seed_two_companies()

      config = Config.load()

      config
      |> put_in(["companies", "acme"], Map.merge(config["companies"]["acme"], %{"markup" => 1.5, "budget" => 200}))
      |> Map.put("root", %{"markup" => 9.9, "budget" => 9999})
      |> Config.save()

      assert {:ok, extracted, _report} = Config.extract_config("acme")

      # acme's own caps ride along as the new install's root scope...
      assert extracted["root"]["markup"] == 1.5
      assert extracted["root"]["budget"] == 200
      # ...and the operator's own root billing (a different tenant's policy) does not leak.
      refute extracted["root"]["markup"] == 9.9
    end

    test "a root model referenced only by a cron override or a triage hook is still pulled in" do
      seed_two_companies()

      # Two shared models that NO agent's `.model` points at - reached only through a cron's model
      # override and an agent's triage hook. A dependency scan that only looked at `.model` would
      # drop them and leave dangling references on the restored install.
      Config.put_model(%Model{name: "shared-cron", base_url: "https://x/v1", api_key: "k", model: "g"})
      Config.put_model(%Model{name: "shared-triage", base_url: "https://x/v1", api_key: "k", model: "g"})
      Config.put_cron(%Cron{id: "c2", agent: "acme/sales", prompt: "x", schedule: "0 9 * * *", model: "shared-cron"})
      Config.put_agent(%Agent{name: "acme/sales", model: "acme/gpt", triage_model: "shared-triage"})

      assert {:ok, config, _report} = Config.extract_config("acme")

      names = config["models"] |> Map.values() |> Enum.map(& &1["name"])
      assert "shared-cron" in names
      assert "shared-triage" in names
    end

    test "an agent's triage_model and fallbacks are de-scoped like its model" do
      seed_two_companies()

      Config.put_model(%Model{name: "acme/triage", base_url: "https://x/v1", api_key: "k", model: "g"})
      Config.put_model(%Model{name: "acme/backup", base_url: "https://x/v1", api_key: "k", model: "g"})

      Config.put_agent(%Agent{
        name: "acme/sales",
        model: "acme/gpt",
        triage_model: "acme/triage",
        fallbacks: ["acme/backup"]
      })

      assert {:ok, config, _report} = Config.extract_config("acme")

      # The company prefix is stripped from the hook fields, matching the now-bare model names.
      assert config["agents"]["sales"]["triage_model"] == "triage"
      assert config["agents"]["sales"]["fallbacks"] == ["backup"]
    end

    test "the report is honest about a raw credential that DID travel in the archive" do
      seed_two_companies()

      # An OAuth-login model stores its live tokens inline, not as ${VAR}; a model with an inline
      # api_key does the same. These are in the archive, so the report must say so rather than let
      # "no secret is in the archive" stand as the whole truth.
      Config.put_model(%Model{name: "acme/subscription", model: "g", base_url: "https://x/v1", api_key: "sk-live-abc"})
      Config.put_agent(%Agent{name: "acme/oauthuser", model: "acme/subscription", system_prompt: "x"})

      assert {:ok, _config, report} = Config.extract_config("acme")

      assert Enum.any?(report.literal_secrets, &(&1 =~ "subscription"))
    end
  end

  describe "extract then restore, end to end" do
    test "the company stands up on a fresh home as a root install", %{home: _home} do
      seed_two_companies()

      out = Path.join(System.tmp_dir!(), "acme_#{System.unique_integer([:positive])}.tgz")
      on_exit(fn -> File.rm_rf(out) end)

      assert {:ok, %{output: ^out, secrets: secrets}} =
               Bundle.extract("acme", output: out, today: ~D[2026-07-14])

      assert "ACME_KEY" in secrets
      assert File.regular?(out)

      # A brand-new machine: nothing here yet.
      fresh = Path.join(System.tmp_dir!(), "pepe_fresh_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(fresh) end)

      assert {:ok, %{home: ^fresh, secrets: restored_secrets}} = Bundle.restore(out, home: fresh)
      assert "ACME_KEY" in restored_secrets

      config = fresh |> Path.join("config.json") |> File.read!() |> Jason.decode!()

      # Root install: bare agents, no company scoping, globex nowhere in sight.
      assert Map.keys(config["agents"]) |> Enum.sort() == ["sales", "support"]
      refute Map.has_key?(config, "companies")

      # The workspace travelled and now lives at the root layout.
      assert File.read!(Path.join([fresh, "agents", "sales", "SOUL.md"])) == "I am sales"
      assert File.read!(Path.join([fresh, "shared", "notes.md"])) == "shared acme note"

      # The ledger travelled and its per-line handle was de-scoped in step.
      ledger = Path.join([fresh, "data", "usage", "root", "2026-07.jsonl"]) |> File.read!()
      assert ledger =~ ~s("agent":"sales")
      refute ledger =~ "acme/sales"
    end

    test "restore refuses to write over a non-empty home unless forced" do
      seed_two_companies()
      out = Path.join(System.tmp_dir!(), "acme_#{System.unique_integer([:positive])}.tgz")
      on_exit(fn -> File.rm_rf(out) end)
      {:ok, _} = Bundle.extract("acme", output: out, today: ~D[2026-07-14])

      occupied = Path.join(System.tmp_dir!(), "pepe_occupied_#{System.unique_integer([:positive])}")
      File.mkdir_p!(occupied)
      File.write!(Path.join(occupied, "keep.txt"), "do not clobber me")
      on_exit(fn -> File.rm_rf(occupied) end)

      assert Bundle.restore(out, home: occupied) == {:error, :home_not_empty}
      # The guard held: the existing file is untouched.
      assert File.read!(Path.join(occupied, "keep.txt")) == "do not clobber me"

      # With force, it replaces what was there.
      assert {:ok, _} = Bundle.restore(out, home: occupied, force: true)
      refute File.exists?(Path.join(occupied, "keep.txt"))
      assert File.regular?(Path.join(occupied, "config.json"))
    end

    test "a restore that fails leaves the existing install untouched, not half-wiped" do
      # A --force restore of a broken archive must not delete the current install before it knows
      # it can write the new one. The old delete-then-copy did exactly that: a bad archive left
      # the operator with neither install.
      occupied = Path.join(System.tmp_dir!(), "pepe_keep_#{System.unique_integer([:positive])}")
      File.mkdir_p!(occupied)
      File.write!(Path.join(occupied, "config.json"), ~s({"real":"install"}))
      on_exit(fn -> File.rm_rf(occupied) end)

      bad = Path.join(System.tmp_dir!(), "not-a-tarball-#{System.unique_integer([:positive])}.tgz")
      File.write!(bad, "this is not a gzip archive")
      on_exit(fn -> File.rm_rf(bad) end)

      assert {:error, {:untar_failed, _}} = Bundle.restore(bad, home: occupied, force: true)
      # The existing install is exactly as it was.
      assert File.read!(Path.join(occupied, "config.json")) == ~s({"real":"install"})
    end
  end
end
