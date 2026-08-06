defmodule Pepe.SearchTest do
  @moduledoc "Pepe.Search is the web_search-slot counterpart to Pepe.Memory - a thin Guard wrapper, nothing more."
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_search_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "search/2 routes through the web_search slot's current occupant", %{home: home} do
    File.write!(Path.join([home, "plugins", "stub_search.exs"]), """
    defmodule PepeSearchTest.Stub do
      @behaviour Pepe.Search.Backend
      def name, do: "stub_search"
      def slot, do: "web_search"
      def search(query, _opts), do: {:ok, [%Pepe.Search.Result{snippet: "echo: " <> query}]}
    end
    """)

    Pepe.Config.put_slot("web_search", "stub_search")

    assert {:ok, [%Pepe.Search.Result{snippet: "echo: hello"}]} = Pepe.Search.search("hello")
  end
end
