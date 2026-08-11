defmodule Pepe.LLM.ModelSelect do
  @moduledoc """
  Default `model_select` slot occupant: today's static chain
  (`Pepe.Config.model_chain_for_agent/1`), unchanged for anyone who hasn't installed a
  plugin here. See `Pepe.Slots` for the slot mechanism.
  """

  def name, do: "builtin"
  def slot, do: "model_select"
  def chain_for(agent), do: {:ok, Pepe.Config.model_chain_for_agent(agent)}
end
