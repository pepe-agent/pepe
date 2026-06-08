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

  test "a huge adversarial input is handled in linear time (no ReDoS)" do
    # A long run of capitals is the worst case for the two adjacent env-name classes; bounding
    # them to {0,64} keeps it linear. Should finish in milliseconds, nowhere near this ceiling.
    big = String.duplicate("A", 200_000) <> "=x"
    {micros, out} = :timer.tc(fn -> Redact.scrub(big) end)
    assert is_binary(out)
    assert micros < 2_000_000, "took #{micros}µs - a quadratic blowup would be far worse"
  end
end
