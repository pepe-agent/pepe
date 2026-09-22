defmodule Pepe.Webhooks.Supervisor do
  @moduledoc """
  The processes behind inbound webhook messages: the per-conversation lanes
  (`Pepe.Webhooks.Lane`) and where they run, the memory of what was already received
  (`Pepe.Webhooks.Dedup`), and the tasks that download, transcribe and deliver.

  Always started, not only when serving: a one-shot command that feeds a webhook payload
  through `Pepe.Webhooks` (a test, a replay) needs the same order and the same duplicate
  check as a live endpoint.
  """
  use Supervisor

  def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg) do
    children = [
      Pepe.Webhooks.Dedup,
      {Registry, keys: :unique, name: Pepe.Webhooks.LaneRegistry},
      {DynamicSupervisor, name: Pepe.Webhooks.LaneSup, strategy: :one_for_one},
      {Task.Supervisor, name: Pepe.Webhooks.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
