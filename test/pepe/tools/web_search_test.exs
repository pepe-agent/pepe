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

  describe "the web_search slot is swappable" do
    setup do
      home = Path.join(System.tmp_dir!(), "pepe_wsslot_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(home, "plugins"))
      prev = System.get_env("PEPE_HOME")
      System.put_env("PEPE_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
        File.rm_rf(home)
      end)

      {:ok, home: home}
    end

    test "pinning web_search to an installed plugin routes the tool through it, not DuckDuckGo", %{home: home} do
      File.write!(Path.join([home, "plugins", "stub_search.exs"]), """
      defmodule PepeWebSearchSlotTest.Stub do
        @behaviour Pepe.Search.Backend
        def name, do: "stub_search"
        def slot, do: "web_search"
        def search(query, _opts), do: {:ok, [%Pepe.Search.Result{title: "From the plugin", snippet: "matched \#{query}"}]}
      end
      """)

      Pepe.Config.put_slot("web_search", "stub_search")

      # Req is stubbed to fail loudly if DuckDuckGo is still the one actually called.
      Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: 500, body: %{}}} end)

      {:ok, out} = WebSearch.run(%{"query" => "pepe"}, %{})
      assert out =~ "From the plugin"
      assert out =~ "matched pepe"
    end
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
