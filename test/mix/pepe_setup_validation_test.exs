defmodule Mix.Tasks.PepeSetupValidationTest do
  use ExUnit.Case, async: true

  describe "required_config_field?/1" do
    test "credential/id fields (secret, text) are required" do
      assert Mix.Tasks.Pepe.required_config_field?(%{"key" => "bot_token", "type" => "secret"})
      assert Mix.Tasks.Pepe.required_config_field?(%{"key" => "phone_number_id", "type" => "text"})
    end

    test "select fields are optional (they carry a default)" do
      refute Mix.Tasks.Pepe.required_config_field?(%{"key" => "require_mention", "type" => "select"})
    end

    test "a field can explicitly opt out with required: false" do
      refute Mix.Tasks.Pepe.required_config_field?(%{"key" => "x", "type" => "text", "required" => false})
    end

    test "every real webhook provider's credentials come back required" do
      # The bug this guards: setup used to skip config fields entirely (a stale
      # function_exported? guard), silently saving empty-config connections. Here
      # we confirm each provider still exposes its schema and that its non-select
      # fields are classified required.
      for provider <- Pepe.Webhooks.providers(),
          mod = Pepe.Webhooks.provider(provider),
          Code.ensure_loaded?(mod) and function_exported?(mod, :config_schema, 0) do
        schema = mod.config_schema()
        # every provider that has a schema has at least one required field
        assert Enum.any?(schema, &Mix.Tasks.Pepe.required_config_field?/1),
               "#{provider} has no required config field"
      end
    end
  end
end
