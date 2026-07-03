defmodule Pepe.Media.VisionTest do
  @moduledoc """
  The policy that turns an inbound image file into something a vision model can see: a byte cap and
  a parts cap (both from `media.image`, with defaults), and the supported-type check. Over-cap,
  unreadable, or unsupported files return `:none` so the caller falls back to the file-path prompt.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Media.Vision

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_vision_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp write_image(home, name, bytes) do
    path = Path.join(home, name)
    File.write!(path, bytes)
    path
  end

  test "defaults: 5 MB and 4 parts when unconfigured" do
    assert Vision.max_bytes() == 5_000_000
    assert Vision.max_parts() == 4
  end

  test "limits are read from media.image config" do
    Config.put_media("image", %{"max_mb" => 2, "max_parts" => 10})
    assert Vision.max_bytes() == 2_000_000
    assert Vision.max_parts() == 10
  end

  test "loads a supported image under the cap", %{home: home} do
    path = write_image(home, "shot.png", "small-bytes")
    assert {:ok, %{media_type: "image/png"}} = Vision.load(path)
  end

  test "refuses an image over the byte cap", %{home: home} do
    Config.put_media("image", %{"max_mb" => 1})
    big = write_image(home, "big.jpg", String.duplicate("x", 1_000_001))
    assert Vision.load(big) == :none
  end

  test "refuses an unsupported type and a missing file", %{home: home} do
    txt = write_image(home, "note.txt", "hello")
    assert Vision.load(txt) == :none
    assert Vision.load(Path.join(home, "gone.png")) == :none
  end
end
