defmodule Pepe.Tools.TelegramPollTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Config
  alias Pepe.Tools.TelegramPoll

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_tgpoll_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_telegram(%{"bot_token" => "T", "allowed_chats" => []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "posts a regular poll to the session's chat" do
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200}}
    end)

    ctx = %{session_key: "telegram:842064390"}
    args = %{"question" => "Pizza or sushi?", "options" => ["Pizza", "Sushi"]}

    assert {:ok, msg} = TelegramPoll.run(args, ctx)
    assert msg =~ "Poll posted"
    assert_received {:req, url, opts}
    assert url =~ "/sendPoll"
    assert opts[:json][:chat_id] == "842064390"
    assert opts[:json][:question] == "Pizza or sushi?"
    assert opts[:json][:options] == [%{text: "Pizza"}, %{text: "Sushi"}]
    assert opts[:json][:is_anonymous] == true
    assert opts[:json][:allows_multiple_answers] == false
  end

  test "builds a quiz poll with the correct option index" do
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200}}
    end)

    ctx = %{session_key: "telegram:1"}
    args = %{"question" => "2+2?", "options" => ["3", "4"], "quiz" => true, "correct_option" => 1}

    assert {:ok, _} = TelegramPoll.run(args, ctx)
    assert_received {:req, _url, opts}
    assert opts[:json][:type] == "quiz"
    assert opts[:json][:correct_option_id] == 1
  end

  test "refuses a quiz poll with no correct_option" do
    ctx = %{session_key: "telegram:1"}
    args = %{"question" => "2+2?", "options" => ["3", "4"], "quiz" => true}

    assert {:error, msg} = TelegramPoll.run(args, ctx)
    assert msg =~ "correct_option"
  end

  test "refuses fewer than 2 options" do
    ctx = %{session_key: "telegram:1"}
    args = %{"question" => "Well?", "options" => ["Only one"]}

    assert {:error, msg} = TelegramPoll.run(args, ctx)
    assert msg =~ "2 to 10"
  end

  test "refuses to run outside a Telegram conversation" do
    ctx = %{session_key: "api:1"}
    args = %{"question" => "Q?", "options" => ["A", "B"]}

    assert {:error, msg} = TelegramPoll.run(args, ctx)
    assert msg =~ "Telegram"
  end
end
