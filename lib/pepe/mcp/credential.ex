defmodule Pepe.MCP.Credential do
  @moduledoc """
  The OAuth grant Pepe holds for one remote MCP server: the tokens themselves plus the
  endpoints and client identity needed to refresh them without repeating discovery.

  In `Pepe.Repo` (SQLite) rather than `config.json`, and the reason is the rule that
  separates the two stores rather than a preference. `config.json` holds *definitions* -
  hand-editable, git-diffable, and where a secret appears only as a `${ENV_VAR}` name. None
  of that fits here: an access token rotates on its own schedule, a refresh token is
  replaced by the act of using it, and neither can be an environment variable because
  nothing outside this process knows the new value. Writing them to `config.json` would put
  live rotating credentials in the file most likely to be copied, committed, or pasted into
  a bug report.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:server, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "mcp_credentials" do
    # Where the token came from, kept so a refresh doesn't have to re-discover.
    field :issuer, :string
    field :token_url, :string
    field :registration_url, :string
    field :client_id, :string
    field :client_secret, :string
    field :scope, :string
    # The MCP server URL the token is bound to (RFC 8707 `resource`), which the
    # authorization server may check on refresh as well as on issue.
    field :resource, :string
    field :access_token, :string
    field :refresh_token, :string
    field :expires_at, :integer
    field :created, :integer
  end

  @type t :: %__MODULE__{}

  @fields ~w(server issuer token_url registration_url client_id client_secret scope
             resource access_token refresh_token expires_at created)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, @fields)
    |> validate_required([:server, :access_token])
  end

  @doc """
  The map shape `Pepe.OAuth.refresh/1` takes. Kept here, next to the fields it reads, so a
  renamed column breaks compilation rather than silently refreshing with a nil client id.
  """
  @spec to_oauth(t()) :: map()
  def to_oauth(%__MODULE__{} = credential) do
    %{
      "token_url" => credential.token_url,
      "refresh" => credential.refresh_token,
      "client_id" => credential.client_id,
      "client_secret" => credential.client_secret,
      "token_content_type" => "form",
      "token_extra_params" => resource_param(credential.resource)
    }
  end

  defp resource_param(nil), do: %{}
  defp resource_param(""), do: %{}
  defp resource_param(resource), do: %{"resource" => resource}
end
