defmodule PepeWeb.BalanceWebhookController do
  @moduledoc """
  `POST /webhooks/balance/:project` - a generic, provider-agnostic endpoint for
  crediting a project's prepaid balance (see `Pepe.Usage.Prepaid`) from a payment
  received. Deliberately generic rather than integrating one specific payment
  processor's SDK/signature scheme (Stripe, a crypto gateway, ...): point your own
  payment processor's own webhook handler at this endpoint (a small relay function,
  a Zapier/Make step, or a direct webhook if the processor lets you set a static
  bearer token) once it has already verified the payment on its end.

  Body: `{"amount": 10.0}` (in the billing currency). Auth: `Authorization: Bearer
  <secret>`, checked against `Pepe.Config.balance_webhook_secret/0` with a constant-time
  comparison - unset means this endpoint is off, refusing every request rather than
  accepting an unauthenticated credit to a real balance.
  """
  use PepeWeb, :controller

  alias Pepe.Config
  alias Pepe.Usage.Prepaid

  def credit(conn, %{"project" => project} = params) do
    with {:ok, secret} <- configured_secret(),
         {:ok, token} <- bearer_token(conn),
         true <- Plug.Crypto.secure_compare(token, secret),
         {:ok, amount} <- fetch_amount(params) do
      case Prepaid.credit(project_scope(project), amount) do
        {:ok, balance} -> json(conn, %{"ok" => true, "balance" => balance})
        {:error, reason} -> conn |> put_status(422) |> json(%{"ok" => false, "error" => to_string(reason)})
      end
    else
      {:error, :not_configured} -> send_resp(conn, 404, "not found")
      {:error, :no_amount} -> conn |> put_status(400) |> json(%{"ok" => false, "error" => "amount must be a positive number"})
      _ -> send_resp(conn, 401, "unauthorized")
    end
  end

  defp configured_secret do
    case Config.balance_webhook_secret() do
      nil -> {:error, :not_configured}
      s -> {:ok, s}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp fetch_amount(%{"amount" => amount}) when is_number(amount) and amount > 0, do: {:ok, amount}

  defp fetch_amount(%{"amount" => amount}) when is_binary(amount) do
    case Float.parse(amount) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :no_amount}
    end
  end

  defp fetch_amount(_), do: {:error, :no_amount}

  # "root" (the CLI/dashboard's own spelling for the default scope) resolves the same
  # way project_cmd's scope_arg/1 does; Pepe.Usage.Prepaid itself already treats a bare
  # nil/"" the same as the default project, so this only needs to catch "root".
  defp project_scope("root"), do: nil
  defp project_scope(project), do: project
end
