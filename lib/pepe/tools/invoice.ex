defmodule Pepe.Tools.Invoice do
  @moduledoc """
  Generate a billing invoice for a project from metered token usage, saved as a
  file and returned inline. Lets an agent produce (and then send) an invoice on its
  own - e.g. a monthly scheduled task that exports each client's invoice and emails
  it.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config
  alias Pepe.Usage
  alias Pepe.Usage.Invoice

  @impl true
  def name, do: "export_invoice"

  @impl true
  def spec do
    function(
      "export_invoice",
      "Generate a billing invoice for a project over a calendar month, from metered " <>
        "token usage. Saves it as a file and returns the rendered invoice plus the file " <>
        "path (attach it or paste it when sending to the client).",
      %{
        "type" => "object",
        "properties" => %{
          "project" => %{
            "type" => "string",
            "description" => "Project (tenant) to bill, e.g. \"acme\"."
          },
          "month" => %{
            "type" => "string",
            "description" => "Month as YYYY-MM. Defaults to the current month."
          },
          "format" => %{
            "type" => "string",
            "enum" => ["markdown", "csv"],
            "description" => "markdown (a readable statement) or csv (for spreadsheets). Default markdown."
          }
        },
        "required" => ["project"]
      }
    )
  end

  @impl true
  def run(%{"project" => project} = args, _ctx) do
    if Config.project_exists?(project) do
      inv = Usage.invoice(project, month: args["month"])
      format = if args["format"] == "csv", do: :csv, else: :markdown

      {body, ext} =
        case format do
          :csv -> {Invoice.to_csv(inv), "csv"}
          :markdown -> {Invoice.to_markdown(inv), "md"}
        end

      dir = Path.join([Config.home(), "data", "invoices"])
      File.mkdir_p!(dir)
      path = Path.join(dir, "#{Invoice.basename(inv)}.#{ext}")
      File.write!(path, body)

      {:ok, "Saved invoice to #{path}\n\n#{body}"}
    else
      {:error, "unknown project: #{project}"}
    end
  end
end
