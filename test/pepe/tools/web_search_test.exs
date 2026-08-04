defmodule Pepe.Tools.WebSearchTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Tools.WebSearch

  defp stub_response(status, body) do
    Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: status, body: body}} end)
  end

  test "missing query still errors as before" do
    assert {:error, "missing 'query'"} = WebSearch.run(%{}, %{})
  end

  test "a non-200 status is reported as an error" do
    stub_response(503, %{})
    assert {:error, msg} = WebSearch.run(%{"query" => "x"}, %{})
    assert msg =~ "503"
  end

  test "the abstract and related topics are joined" do
    stub_response(200, %{"AbstractText" => "The answer.", "RelatedTopics" => [%{"Text" => "See also this."}]})

    {:ok, out} = WebSearch.run(%{"query" => "x"}, %{})

    assert out =~ "The answer."
    assert out =~ "See also this."
  end

  describe "untrusted content marker" do
    test "a result is wrapped in an explicit untrusted-content marker" do
      stub_response(200, %{"AbstractText" => "The answer.", "RelatedTopics" => []})

      {:ok, out} = WebSearch.run(%{"query" => "x"}, %{})

      assert out =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
      assert out =~ "source: web_search"
      assert out =~ "END UNTRUSTED EXTERNAL CONTENT"
      assert out =~ "The answer."
    end

    test "even an empty result is wrapped, not left bare" do
      stub_response(200, %{})

      {:ok, out} = WebSearch.run(%{"query" => "x"}, %{})

      assert out =~ "No instant answer found."
      assert out =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
    end
  end
end
