defmodule Pepe.PepeHubTest do
  @moduledoc """
  Resolving an `@handle/name` reference (or the package's own page URL) against PepeHub.
  """
  use ExUnit.Case, async: false

  alias Pepe.PepeHub

  defmodule HubPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/api/v1/packages/@jhonathas/google-workspace"} = conn, _opts) do
      json(conn, 200, %{
        "name" => "@jhonathas/google-workspace",
        "kind" => "skill",
        "official" => Elixir.Agent.get(:pepe_hub_official, & &1),
        "latestVersion" => "1.2.0"
      })
    end

    def call(%{request_path: "/api/v1/packages/@jhonathas/backup-tool"} = conn, _opts) do
      json(conn, 200, %{"name" => "@jhonathas/backup-tool", "kind" => "plugin", "official" => false, "latestVersion" => "0.3.1"})
    end

    def call(%{request_path: "/api/v1/packages/@jhonathas/unpublished"} = conn, _opts) do
      json(conn, 200, %{"name" => "@jhonathas/unpublished", "kind" => "skill", "official" => false, "latestVersion" => nil})
    end

    def call(%{request_path: "/api/v1/packages/" <> _} = conn, _opts) do
      json(conn, 404, %{"error" => "not_found", "message" => "not found"})
    end

    def call(conn, _opts), do: json(conn, 404, %{"error" => "not_found"})

    defp json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    {:ok, _} = Elixir.Agent.start_link(fn -> false end, name: :pepe_hub_official)
    server = start_supervised!({Bandit, plug: HubPlug, port: 0, scheme: :http})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    base = "http://localhost:#{port}"

    prev = Application.get_env(:pepe, :pepe_hub_base_url)
    Application.put_env(:pepe, :pepe_hub_base_url, base)

    on_exit(fn ->
      if prev, do: Application.put_env(:pepe, :pepe_hub_base_url, prev), else: Application.delete_env(:pepe, :pepe_hub_base_url)
    end)

    %{base: base}
  end

  defp official!(value), do: Elixir.Agent.update(:pepe_hub_official, fn _ -> value end)

  describe "parse/1 and reference?/1" do
    test "a bare @handle/name shorthand parses to itself" do
      assert PepeHub.parse("@jhonathas/google-workspace") == {:ok, "@jhonathas/google-workspace"}
      assert PepeHub.reference?("@jhonathas/google-workspace")
    end

    test "the package's own page URL parses to the same canonical name", %{base: base} do
      assert PepeHub.parse("#{base}/packages/@jhonathas/google-workspace") == {:ok, "@jhonathas/google-workspace"}
      assert PepeHub.parse("#{base}/packages/@jhonathas/google-workspace/") == {:ok, "@jhonathas/google-workspace"}
    end

    test "a page URL on a different host is not a PepeHub reference" do
      assert PepeHub.parse("https://example.com/packages/@jhonathas/google-workspace") == :error
      refute PepeHub.reference?("https://example.com/packages/@jhonathas/google-workspace")
    end

    test "an ordinary bare name, a path, or an arbitrary URL is not a PepeHub reference" do
      refute PepeHub.reference?("vaults")
      refute PepeHub.reference?("/local/path/to/skill.md")
      refute PepeHub.reference?("https://github.com/octocat/Hello-World")
    end
  end

  test "local_name/1 strips the scope for a PepeHub reference, and passes anything else through" do
    assert PepeHub.local_name("@jhonathas/google-workspace") == "google-workspace"
    assert PepeHub.local_name("vaults") == "vaults"
    assert PepeHub.local_name("https://github.com/octocat/Hello-World") == "https://github.com/octocat/Hello-World"
  end

  describe "resolve/1" do
    test "a skill package resolves with its kind, versioned download URL, and community trust" do
      official!(false)

      assert {:ok, %{kind: "skill", download_url: url, trust: "community"}} = PepeHub.resolve("@jhonathas/google-workspace")
      assert url =~ "/api/v1/packages/@jhonathas/google-workspace/versions/1.2.0/download"
    end

    test "official: true on the package becomes official trust, never self-declared by anything else" do
      official!(true)
      assert {:ok, %{trust: "official"}} = PepeHub.resolve("@jhonathas/google-workspace")
    end

    test "a plugin package resolves with kind: plugin" do
      assert {:ok, %{kind: "plugin", download_url: url}} = PepeHub.resolve("@jhonathas/backup-tool")
      assert url =~ "/versions/0.3.1/download"
    end

    test "resolving via the full page URL is identical to the shorthand", %{base: base} do
      official!(false)
      assert PepeHub.resolve("#{base}/packages/@jhonathas/google-workspace") == PepeHub.resolve("@jhonathas/google-workspace")
    end

    test "a package that doesn't exist on PepeHub" do
      assert {:error, :not_found} = PepeHub.resolve("@jhonathas/nope-#{System.unique_integer([:positive])}")
    end

    test "a real package with no published version yet" do
      assert {:error, :no_published_version} = PepeHub.resolve("@jhonathas/unpublished")
    end

    test "not a PepeHub reference at all" do
      assert {:error, :invalid_reference} = PepeHub.resolve("vaults")
    end
  end
end
