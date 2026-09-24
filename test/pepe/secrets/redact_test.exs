defmodule Pepe.Secrets.RedactTest do
  use ExUnit.Case, async: true

  alias Pepe.Secrets.Redact

  test "masks an env-style secret assignment, keeping the ordinary part" do
    out = Redact.scrub("PGPASSWORD=s3cr3t-p4ssw0rd-value\nPATH=/usr/bin")
    refute out =~ "s3cr3t-p4ssw0rd-value"
    assert out =~ "PGPASSWORD="
    assert out =~ "PATH=/usr/bin"
  end

  test "masks a named secret key in json/query/form shapes" do
    for text <- [
          ~s({"api_key": "abcdef1234567890xyz"}),
          "https://x.com/cb?token=abcdef1234567890xyz&page=2",
          "client_secret=abcdef1234567890xyz"
        ] do
      out = Redact.scrub(text)
      refute out =~ "abcdef1234567890xyz", "should mask in: #{text}"
    end
  end

  test "masks a Bearer token, a JWT, and a bot-token shape" do
    jwt = "eyJhbGciOiJI.eyJzdWIiOiIx.abcDEF123456"
    out = Redact.scrub("Authorization: Bearer abcdef1234567890TOKEN\ntok #{jwt}\n123456:AAbb-cc_ddeeffgghhiijjkkll")
    refute out =~ "abcdef1234567890TOKEN"
    refute out =~ jwt
    refute out =~ "AAbb-cc_ddeeffgghhiijjkkll"
  end

  test "keeps a first/last hint on a long value, blanks a short one" do
    assert Redact.scrub("password=abcdefghijklmnopqrstuvwxyz") =~ ~r/password=abcd….{0,4}wxyz/
    assert Redact.scrub("password=short1") =~ "password=***"
  end

  test "leaves ordinary key=value output alone" do
    text = "count=42\nstatus=active\nname=jhonathas\nport=5432"
    assert Redact.scrub(text) == text
  end

  test "does not trip on words that merely end in a secret word" do
    # MONKEY ends in KEY, LINKED ends in KED not a secret word - neither should be masked.
    text = "MONKEY=banana\nLINKED=true"
    assert Redact.scrub(text) == text
  end

  test "non-binary passes through" do
    assert Redact.scrub(nil) == nil
    assert Redact.scrub(42) == 42
  end

  test "masks a bare high-entropy secret with no recognizable shape at all" do
    # Deliberately not shaped like any real vendor's key prefix (sk_live_, ghp_, AKIA, ...) -
    # a fixture that happens to match one trips GitHub's own push-protection secret scanner.
    secret = "qP9zK3mR7vT4cB6dY1wL5hJ0eN2aF8xSbQ4rK"
    out = Redact.scrub("the key is #{secret} which you can use now")
    refute out =~ secret
    assert out =~ "the key is"
  end

  test "leaves a git commit SHA / hex hash alone" do
    text = "fixed in commit a3f5e8b9c1d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0"
    assert Redact.scrub(text) == text
  end

  test "leaves a git commit SHA alone even at the end of a sentence (regression: the trailing period joined the candidate)" do
    text = "fixed in commit a3f5e8b9c1d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0."
    assert Redact.scrub(text) == text
  end

  test "leaves long identifiers, module names and hostnames alone (regression: word_segments treated them as one random run)" do
    text =
      "handle_incoming_webhook_request Pepe.Config.redact_tool_output " <>
        "Pepe.Agent.SkillLearning.maybe_offer ec2-54-12-34-56.compute-1.amazonaws.com"

    assert Redact.scrub(text) == text
  end

  test "masks an unpadded base64-style secret with a single slash (regression: path_like? excluded it on one / alone)" do
    secret = "qP9zK3mR7vT4cB6dY1wL5hJ0eN2aF8/x"
    out = Redact.scrub("token is #{secret} here")
    refute out =~ secret
    assert out =~ "token is"
  end

  test "does not leave a short tail exposed past the old 4096-character candidate cap" do
    # Genuinely varied content, not a repeating pattern - a repeat has low real entropy no
    # matter how long it runs, and would never have cleared the mask bar to begin with, which
    # would make this pass for the wrong reason instead of exercising the cap.
    pool = ~w(a b c d e f g h A B C D 0 1 2 3 4 5 6 7 8 9)
    long_run = for _ <- 1..4200, into: "", do: Enum.random(pool)
    long_secret = long_run <> "shorttail1234567890"
    out = Redact.scrub("value seen: #{long_secret} end")
    refute out =~ "shorttail1234567890"
  end

  test "masks a base64url-style secret using - and _ as encoding characters, not word separators" do
    secret = "aB3xY9m-qW2mK7pL4n-R8vT1cF6d-S0hJ5gN2mQ8"
    out = Redact.scrub("value seen: #{secret} end")
    refute out =~ secret
    assert out =~ "value seen:"
  end

  test "still leaves a compound PascalCase module/type name alone" do
    text = "Pepe.Agent.SkillLearning.maybe_offer and Pepe.Security.ExternalContent"
    assert Redact.scrub(text) == text
  end

  test "leaves a UUID alone" do
    text = "the request id was 550e8400-e29b-41d4-a716-446655440000 for this trace"
    assert Redact.scrub(text) == text
  end

  test "leaves a file path alone" do
    text = "the file lives at /Users/jhonathas/lib/pepe/secrets/redact.ex on disk"
    assert Redact.scrub(text) == text
  end

  test "leaves a PATH-shaped env var alone (regression: its = is a key/value separator, not base64 padding)" do
    text = "PATH=/usr/local/bin:/opt/homebrew/bin:/Users/jhonathas/.bun/bin:/opt/homebrew/opt/icu4c@77/sbin"
    assert Redact.scrub(text) == text
  end

  test "leaves an ordinary long sentence and a long low-entropy run alone" do
    sentence = "this is just a normal sentence with no secrets in it at all, nothing to see here"
    assert Redact.scrub(sentence) == sentence

    repeated = String.duplicate("a", 60)
    assert Redact.scrub(repeated) == repeated
  end

  test "a huge adversarial input is handled in linear time (no ReDoS)" do
    # A long run of capitals is the worst case for the two adjacent env-name classes; bounding
    # them to {0,64} keeps it linear. Should finish in milliseconds, nowhere near this ceiling.
    big = String.duplicate("A", 200_000) <> "=x"
    {micros, out} = :timer.tc(fn -> Redact.scrub(big) end)
    assert is_binary(out)
    assert micros < 2_000_000, "took #{micros}µs - a quadratic blowup would be far worse"
  end

  test "a huge run of token-charset input for the entropy pass is also handled in linear time" do
    big = String.duplicate("aB3", 100_000)
    {micros, out} = :timer.tc(fn -> Redact.scrub(big) end)
    assert is_binary(out)
    assert micros < 2_000_000, "took #{micros}µs - a quadratic blowup would be far worse"
  end
end
