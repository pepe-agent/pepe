defmodule Pepe.Agent.TopicRerouteTest do
  @moduledoc """
  `topic_reroute`: a specialist that notices the user has moved on asks them yes/no
  (`hand_back`) and, on yes, the conversation goes back to the channel's own agent along
  with the message that triggered it, so the router can route it without the user repeating
  themselves. Driven end to end through a real session against a scripted mock model: the
  specialist calls `hand_back` on its first request, the router answers `ROUTED:<message>`.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_topicreroute_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs FIRST, see Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    Process.register(self(), :pepe_topicreroute_test)
    {:ok, server} = Bandit.start_link(plug: &scripted_mock/2, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Config.put_model(%Model{name: "mock", base_url: "http://127.0.0.1:#{port}", api_key: "x", model: "m"})

    Config.put_agent(%Agent{name: "router", model: "mock", system_prompt: "ROUTER", tools: [], max_iterations: 5})
    Config.put_agent(%Agent{name: "spec", model: "mock", system_prompt: "SPEC", tools: [], max_iterations: 5, topic_reroute: true})

    {:ok, key: "test:topicreroute:#{System.unique_integer([:positive])}"}
  end

  # The specialist asks to hand back on its first request; after the tool result it says
  # something that tells us which result it got. The router just echoes what it was sent.
  defp scripted_mock(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    req = Jason.decode!(body)
    messages = req["messages"]
    tools = for t <- req["tools"] || [], do: t["function"]["name"]
    system = hd(messages)["content"]
    last = List.last(messages)
    role = if system =~ "ROUTER", do: :router, else: :spec
    send(:pepe_topicreroute_test, {:request, role, tools})

    message = reply(role, tools, last)

    payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
    conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp text(content), do: %{"role" => "assistant", "content" => content}

  defp tool_call(id, name, arguments) do
    call = %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => arguments}}
    %{"role" => "assistant", "content" => nil, "tool_calls" => [call]}
  end

  # The router: asks to forward on "ROUTE ME", otherwise echoes the message it was sent.
  defp reply(:router, _tools, %{"role" => "user", "content" => "ROUTE ME" <> _}),
    do: tool_call("call_2", "switch_agent", ~s({"target":"spec","forward_message":true}))

  defp reply(:router, _tools, %{"role" => "tool"}), do: text("ROUTER SHOULD NOT BE SHOWN")
  defp reply(:router, _tools, last), do: text("ROUTED:" <> last["content"])

  # The specialist.
  defp reply(:spec, _tools, %{"role" => "user", "content" => "YES"}),
    do: tool_call("call_3", "hand_back", ~s({"confirmed":true}))

  defp reply(:spec, tools, %{"role" => "user"} = last) do
    if "hand_back" in tools,
      do: tool_call("call_1", "hand_back", ~s({"question":"Switch?","yes":"Yes","no":"No"})),
      else: text("SPEC ANSWERED:" <> last["content"])
  end

  defp reply(:spec, _tools, %{"role" => "tool", "content" => content}) do
    cond do
      content =~ "Handed back" -> text("SPEC SHOULD NOT BE SHOWN")
      content =~ "no buttons" -> text("SPEC ASKED IN TEXT")
      true -> text("SPEC KEPT GOING")
    end
  end

  defp specialist_session(key) do
    {:ok, _} = SessionSupervisor.ensure(key, "router")
    Session.set_agent(key, "spec")
  end

  test "yes: the conversation goes back to the router and the same message is sent on to it", %{key: key} do
    specialist_session(key)
    ask = fn "Switch?", ["Yes", "No"] -> {:ok, "Yes"} end

    assert {:ok, "ROUTED:preciso de marketing"} = Session.chat(key, "preciso de marketing", ask_user: ask)

    assert Session.status(key).agent =~ "router"
    # The specialist was offered the tool; the router, being the channel's own agent, was not.
    assert_received {:request, :spec, tools}
    assert "hand_back" in tools
    assert_received {:request, :router, router_tools}
    refute "hand_back" in router_tools
  end

  test "no: the specialist carries on and the conversation stays with it", %{key: key} do
    specialist_session(key)
    ask = fn _q, _choices -> {:ok, "No"} end

    assert {:ok, "SPEC KEPT GOING"} = Session.chat(key, "preciso de marketing", ask_user: ask)
    assert Session.status(key).agent =~ "spec"
    refute_received {:request, :router, _}
  end

  test "a surface with no buttons is told to ask in plain text, and nothing moves", %{key: key} do
    specialist_session(key)

    assert {:ok, "SPEC ASKED IN TEXT"} = Session.chat(key, "preciso de marketing")
    assert Session.status(key).agent =~ "spec"
  end

  test "with no buttons, the yes re-sends the message that raised the question, not the yes itself", %{key: key} do
    specialist_session(key)

    assert {:ok, "SPEC ASKED IN TEXT"} = Session.chat(key, "preciso de marketing")
    assert {:ok, "ROUTED:preciso de marketing"} = Session.chat(key, "YES")
    assert Session.status(key).agent =~ "router"
  end

  test "an agent without the option is never offered hand_back", %{key: key} do
    Config.put_agent(%Agent{name: "spec", model: "mock", system_prompt: "SPEC", tools: [], max_iterations: 5, topic_reroute: false})
    specialist_session(key)

    Session.chat(key, "oi")
    assert_received {:request, :spec, tools}
    refute "hand_back" in tools
  end

  test "a channel that locks agent switching never offers it", %{key: key} do
    specialist_session(key)

    Session.chat(key, "oi", agent_switch_locked: true)
    assert_received {:request, :spec, tools}
    refute "hand_back" in tools
  end

  test "the router itself, with the option on, is not offered it either", %{key: key} do
    Config.put_agent(%Agent{name: "router", model: "mock", system_prompt: "ROUTER", tools: [], max_iterations: 5, topic_reroute: true})
    {:ok, _} = SessionSupervisor.ensure(key, "router")

    Session.chat(key, "oi")
    assert_received {:request, :router, tools}
    refute "hand_back" in tools
  end

  test "a router's switch_agent can forward the message, so the user does not repeat it", %{key: key} do
    Config.put_agent(%Agent{
      name: "router",
      model: "mock",
      system_prompt: "ROUTER",
      tools: ["switch_agent"],
      auto_approve: ["switch_agent"],
      can_message: ["spec"],
      max_iterations: 5
    })

    Config.put_agent(%Agent{name: "spec", model: "mock", system_prompt: "SPEC", tools: [], max_iterations: 5})
    {:ok, _} = SessionSupervisor.ensure(key, "router")

    assert {:ok, "SPEC ANSWERED:ROUTE ME to marketing"} = Session.chat(key, "ROUTE ME to marketing")
    assert Session.status(key).agent =~ "spec"
  end

  test "the registry hides a tool that is not offered and refuses a call to it at dispatch" do
    router = %Agent{name: "r", tools: ["switch_agent"], can_message: ["spec"], topic_reroute: true}
    open = %{agent: router, agent_switch_locked: false, handback: true}
    locked = %{agent: router, agent_switch_locked: true, handback: true}
    home_agent = %{agent: router, agent_switch_locked: false, handback: false}

    names = fn ctx -> for s <- Pepe.Tools.specs(router.tools, ctx) || [], do: s["function"]["name"] end

    assert names.(open) == ["switch_agent", "hand_back"]
    assert names.(locked) == []
    assert names.(home_agent) == ["switch_agent"]

    call = %{"function" => %{"name" => "hand_back", "arguments" => "{}"}}
    assert Pepe.Tools.execute(call, home_agent) =~ "not available on this turn"
  end

  test "hand_back is not part of any tool list a person picks from" do
    refute "hand_back" in Pepe.Tools.names()
    assert Pepe.Tools.get("hand_back") == Pepe.Tools.HandBack
  end
end
