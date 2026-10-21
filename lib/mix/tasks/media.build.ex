defmodule Mix.Tasks.Media.Build do
  @shortdoc "Builds the media helper (native/browser_media) with the libav libraries"

  @moduledoc """
  Builds `priv/browser_media`, the helper program that decodes audio and video
  (see `docs/media.md`). It needs a C compiler, `pkg-config` and the development files of
  libavformat, libavcodec, libavutil, libswscale and libswresample (`scripts/install-toolchain.sh`
  installs them).

      mix media.build
  """
  use Mix.Task

  @libs ~w(libavformat libavcodec libavutil libswscale libswresample)

  @impl true
  def run(_args) do
    source = Path.join(File.cwd!(), "native/browser_media/media_helper.c")
    out = Path.join(File.cwd!(), "priv/browser_media")

    {flags, status} =
      System.cmd("pkg-config", ["--cflags", "--libs"] ++ @libs, stderr_to_stdout: true)

    if status != 0 do
      Mix.raise(
        "pkg-config cannot find the libav libraries:\n#{flags}\nRun scripts/install-toolchain.sh."
      )
    end

    args = ["-O2", "-Wall", "-o", out, source] ++ String.split(flags)

    case System.cmd("cc", args, stderr_to_stdout: true) do
      {_, 0} -> Mix.shell().info("built #{out}")
      {output, _} -> Mix.raise("the C compiler failed:\n#{output}")
    end
  end
end
