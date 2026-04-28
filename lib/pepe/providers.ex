defmodule Pepe.Providers do
  @moduledoc """
  Catalog of well-known, OpenAI-compatible providers, used by the CLI for a
  guided "pick a company -> pick an auth method -> pick a model" flow.

  Each provider has one or more **auth methods**. Selecting a provider opens its
  submenu of methods:

    * `:api_key` - read the key from `env` (or paste it once); `Authorization: Bearer`.
    * `:oauth`   - subscription sign-in (ChatGPT/Codex, Claude Pro/Max, ...). When the
                   method carries an `:oauth_flow` spec, `Pepe.OAuth` runs the full
                   browser PKCE login (generate link -> open -> capture token); without
                   one it falls back to pasting an access token. An optional
                   `:base_url` overrides the endpoint for that method.
    * `:none`    - local, keyless services.
  """

  @providers [
    %{
      key: "openai",
      label: "OpenAI",
      base_url: "https://api.openai.com/v1",
      env: "OPENAI_API_KEY",
      auth: [
        %{
          key: "codex",
          label: "ChatGPT / Codex subscription (sign in with your browser)",
          button: "ChatGPT / Codex",
          type: :oauth,
          env: "OPENAI_OAUTH_TOKEN",
          featured: true,
          base_url: "https://chatgpt.com/backend-api/codex",
          # The Codex subscription speaks the Responses API, not Chat Completions.
          api: "openai-responses",
          # The CLI lists models live from the Codex /models endpoint; this is only
          # the offline fallback (the `*-codex` ids are rejected by ChatGPT accounts).
          models: ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"],
          oauth_flow: %{
            authorize_url: "https://auth.openai.com/oauth/authorize",
            token_url: "https://auth.openai.com/oauth/token",
            client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
            redirect_uri: "http://localhost:1455/auth/callback",
            callback_port: 1455,
            callback_path: "/auth/callback",
            scope: "openid profile email offline_access",
            token_content_type: :form,
            extra_params: %{
              "id_token_add_organizations" => "true",
              "codex_cli_simplified_flow" => "true",
              "originator" => "pepe"
            }
          }
        },
        %{key: "api", label: "API key", type: :api_key}
      ]
    },
    %{
      key: "anthropic",
      label: "Anthropic (Claude)",
      base_url: "https://api.anthropic.com/v1",
      env: "ANTHROPIC_API_KEY",
      auth: [
        %{
          key: "oauth",
          label: "Claude Pro / Max subscription (sign in with your browser)",
          button: "Claude Pro / Max",
          type: :oauth,
          env: "ANTHROPIC_OAUTH_TOKEN",
          featured: true,
          # Anthropic speaks the Messages API, not Chat Completions - even with an API key.
          base_url: "https://api.anthropic.com/v1",
          api: "anthropic-messages",
          models: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"],
          oauth_flow: %{
            authorize_url: "https://claude.ai/oauth/authorize",
            token_url: "https://platform.claude.com/v1/oauth/token",
            client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            redirect_uri: "http://localhost:53692/callback",
            callback_port: 53_692,
            callback_path: "/callback",
            scope: "org:create_api_key user:profile user:inference",
            token_content_type: :json,
            token_includes_state: true,
            extra_params: %{"code" => "true"}
          }
        },
        %{
          key: "api",
          label: "API key",
          type: :api_key,
          base_url: "https://api.anthropic.com/v1",
          api: "anthropic-messages",
          models: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
        }
      ]
    },
    %{
      key: "openrouter",
      label: "OpenRouter (200+ models)",
      base_url: "https://openrouter.ai/api/v1",
      env: "OPENROUTER_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "groq",
      label: "Groq",
      base_url: "https://api.groq.com/openai/v1",
      env: "GROQ_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "deepseek",
      label: "DeepSeek",
      base_url: "https://api.deepseek.com",
      env: "DEEPSEEK_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "mistral",
      label: "Mistral",
      base_url: "https://api.mistral.ai/v1",
      env: "MISTRAL_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "together",
      label: "Together AI",
      base_url: "https://api.together.xyz/v1",
      env: "TOGETHER_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "xai",
      label: "xAI (Grok)",
      base_url: "https://api.x.ai/v1",
      env: "XAI_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "gemini",
      label: "Google Gemini",
      base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
      env: "GEMINI_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "moonshot",
      label: "Moonshot / Kimi",
      base_url: "https://api.moonshot.ai/v1",
      env: "MOONSHOT_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "zai",
      label: "z.ai / GLM",
      base_url: "https://api.z.ai/api/paas/v4",
      env: "GLM_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "novita",
      label: "NovitaAI",
      base_url: "https://api.novita.ai/v3/openai",
      env: "NOVITA_API_KEY",
      auth: [%{key: "api", label: "API key", type: :api_key}]
    },
    %{
      key: "ollama",
      label: "Ollama (local)",
      base_url: "http://localhost:11434/v1",
      env: nil,
      auth: [%{key: "none", label: "No auth (local)", type: :none}]
    },
    %{
      key: "lmstudio",
      label: "LM Studio (local)",
      base_url: "http://localhost:1234/v1",
      env: nil,
      auth: [%{key: "none", label: "No auth (local)", type: :none}]
    },
    %{
      key: "vllm",
      label: "vLLM (local)",
      base_url: "http://localhost:8000/v1",
      env: nil,
      auth: [%{key: "none", label: "No auth (local)", type: :none}]
    },
    %{
      key: "custom",
      label: "Custom / other (enter base URL manually)",
      base_url: nil,
      env: nil,
      auth: [%{key: "custom", label: "Custom endpoint", type: :custom}]
    }
  ]

  @doc "All known providers."
  def all, do: @providers

  @doc "Look up a provider by slug."
  def get(key), do: Enum.find(@providers, &(&1.key == key))

  @doc "Auth methods for a provider (defaults to a single API-key method)."
  def auth_methods(provider),
    do: provider[:auth] || [%{key: "api", label: "API key", type: :api_key}]

  @doc """
  Providers that offer a subscription (browser OAuth) sign-in, as
  `[%{provider, label, method}]` where `method` is the OAuth auth method (carrying its
  `:oauth_flow`, `:base_url`, `:api`, `:models`). Used to render "Sign in" buttons.
  """
  def subscription_methods do
    Enum.flat_map(@providers, fn p ->
      case Enum.find(p[:auth] || [], &(&1[:type] == :oauth and is_map(&1[:oauth_flow]))) do
        nil -> []
        # Label the button/panel by the subscription being connected (e.g. "ChatGPT /
        # Codex"), not the bare provider name - clearer than "OpenAI", which also has an
        # API-key path.
        method -> [%{provider: p.key, label: method[:button] || p.label, method: method}]
      end
    end)
  end
end
