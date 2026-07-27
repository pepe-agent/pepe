defmodule Pepe.Repo.Migrations.CreateMcpCredentials do
  use Ecto.Migration

  def change do
    create table(:mcp_credentials, primary_key: false) do
      # The MCP server name from config.json's "mcp" map - one grant per server, so the
      # name is the key and a second login for the same server replaces the first rather
      # than leaving two tokens where only one can be the live one.
      add :server, :string, primary_key: true
      add :issuer, :string
      add :token_url, :string
      add :registration_url, :string
      add :client_id, :string
      add :client_secret, :string
      add :scope, :string
      add :resource, :string
      add :access_token, :text
      add :refresh_token, :text
      add :expires_at, :integer
      add :created, :integer
    end
  end
end
