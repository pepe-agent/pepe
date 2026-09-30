defmodule Pepe.LLM.OutputCapParamTest do
  use ExUnit.Case, async: true

  alias Pepe.Config.Model
  alias Pepe.LLM
  alias Pepe.LLM.Responses

  test "OpenAI's own endpoint gets max_completion_tokens, other servers keep max_tokens" do
    assert LLM.output_cap_key(%Model{base_url: "https://api.openai.com/v1"}) == "max_completion_tokens"
    assert LLM.output_cap_key(%Model{base_url: "https://openrouter.ai/api/v1"}) == "max_tokens"
    assert LLM.output_cap_key(%Model{base_url: "http://localhost:11434/v1"}) == "max_tokens"
  end

  test "the ChatGPT subscription backend takes no output cap, the Responses API does" do
    refute Responses.output_cap?(%Model{base_url: "https://chatgpt.com/backend-api/codex"})
    assert Responses.output_cap?(%Model{base_url: "https://api.openai.com/v1"})
    assert Responses.output_cap?(%Model{base_url: "http://127.0.0.1:4000/codex"})
  end
end
