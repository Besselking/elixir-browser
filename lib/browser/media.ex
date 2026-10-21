defmodule Browser.Media do
  @moduledoc """
  Decodes audio and video with a helper program (`native/browser_media`, built by
  `mix media.build`) that links the libav libraries. See `docs/media.md`.

  The helper is an OS process on a Port, so a bad file cannot stop the VM. It decodes only
  when asked: `next_video/1` and `next_audio/1` give one frame or one chunk, so the caller
  decides the timing. The process that calls `open/1` owns the Port and gets its answers.

      {:ok, media} = Browser.Media.open("/tmp/clip.mp4")
      media.info                       # duration, size, streams
      {:ok, media} = Browser.Media.set_size(media, 320, 180)
      {:frame, pts_ms, w, h, rgba} = Browser.Media.next_video(media)
      {:audio, pts_ms, pcm} = Browser.Media.next_audio(media)   # s16le, 2 channels, 48000 Hz
      Browser.Media.close(media)

  The helper reads a file. The caller saves the bytes of a media resource to a file first.
  """

  defstruct [:port, :info]

  @type t :: %__MODULE__{port: port, info: map}

  @timeout 15_000

  @doc "Where the helper program is: `BROWSER_MEDIA_HELPER`, else `priv/browser_media`."
  def helper_path do
    System.get_env("BROWSER_MEDIA_HELPER") ||
      Path.join(Application.app_dir(:browser, "priv"), "browser_media")
  end

  @doc "True when the helper program has been built."
  def available?, do: File.regular?(helper_path())

  @doc "Starts a helper for the file at `path`: `{:ok, media}` or `{:error, text}`."
  @spec open(Path.t()) :: {:ok, t} | {:error, String.t()}
  def open(path) do
    if available?() do
      port =
        Port.open({:spawn_executable, helper_path()}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:packet, 4},
          args: []
        ])

      Port.command(port, ["O", path])

      case await(port) do
        {:info, info} ->
          {:ok, %__MODULE__{port: port, info: info}}

        {:error, text} ->
          close(port)
          {:error, text}
      end
    else
      {:error, "the media helper is not built (mix media.build)"}
    end
  end

  @doc "The size of the frames `next_video/1` gives; `0, 0` is the size of the video."
  def set_size(%__MODULE__{port: port} = media, w, h) do
    Port.command(port, [<<?S, w::32, h::32>>])
    {:ok, media}
  end

  @doc """
  The format of the frames: `:rgba` (the default) or `:bmp`, a whole 24 bit BMP file that
  wxWidgets and `Browser.UI.load_image/3` read as they are.
  """
  def set_format(%__MODULE__{port: port} = media, format) when format in [:rgba, :bmp] do
    Port.command(port, [<<?M, if(format == :bmp, do: 1, else: 0)>>])
    {:ok, media}
  end

  @doc """
  The first frame of a video given as bytes, as a BMP file: `{:ok, bmp, {w, h}}` or
  `{:error, text}`. `width` is the width to scale to (0: the width of the video); the
  height follows the aspect ratio.
  """
  def first_frame(bytes, width \\ 0) do
    path = Path.join(System.tmp_dir!(), "browser-media-#{System.unique_integer([:positive])}")

    try do
      File.write!(path, bytes)

      with {:ok, media} <- open(path) do
        result =
          with true <- media.info.video? or {:error, "no video stream"},
               {:ok, media} <- set_format(media, :bmp),
               {:ok, media} <- scale_to(media, width),
               {:frame, _pts, w, h, bmp} <- next_video(media) do
            {:ok, bmp, {w, h}}
          else
            {:error, _} = error -> error
            other -> {:error, "no frame: #{inspect(other)}"}
          end

        close(media)
        result
      end
    after
      File.rm(path)
    end
  end

  defp scale_to(media, width) when width > 0 and media.info.width > width do
    set_size(media, width, max(div(media.info.height * width, media.info.width), 1))
  end

  defp scale_to(media, _width), do: {:ok, media}

  @doc "The next video frame: `{:frame, pts_ms, w, h, rgba}`, `:end` or `{:error, text}`."
  def next_video(%__MODULE__{port: port}) do
    Port.command(port, "V")
    await(port)
  end

  @doc "The next audio chunk: `{:audio, pts_ms, pcm}`, `:end` or `{:error, text}`."
  def next_audio(%__MODULE__{port: port}) do
    Port.command(port, "A")
    await(port)
  end

  @doc "Moves to `ms`; the next frames and chunks start there (not before)."
  def seek(%__MODULE__{port: port}, ms) do
    Port.command(port, <<?K, ms::32>>)

    case await(port) do
      :seeked -> :ok
      other -> other
    end
  end

  @doc "Stops the helper."
  def close(%__MODULE__{port: port}), do: close(port)

  def close(port) when is_port(port) do
    if Port.info(port) do
      Port.command(port, "Q")
      Port.close(port)
    end

    :ok
  end

  # -- answers -----------------------------------------------------------------------

  defp await(port) do
    receive do
      {^port, {:data, data}} -> decode(data)
      {^port, {:exit_status, status}} -> {:error, "the media helper stopped (#{status})"}
    after
      @timeout -> {:error, "the media helper did not answer"}
    end
  end

  defp decode(<<?I, ms::32, w::32, h::32, has_v, has_a, fps::32, names::binary>>) do
    [vcodec, acodec] = String.split(names, ",", parts: 2)

    {:info,
     %{
       duration_ms: ms,
       width: w,
       height: h,
       video?: has_v == 1,
       audio?: has_a == 1,
       fps: fps / 1000,
       video_codec: vcodec,
       audio_codec: acodec
     }}
  end

  defp decode(<<?v, pts::32, w::32, h::32, rgba::binary>>), do: {:frame, pts, w, h, rgba}
  defp decode(<<?a, pts::32, pcm::binary>>), do: {:audio, pts, pcm}
  defp decode(<<?E, _which>>), do: :end
  defp decode(<<?K>>), do: :seeked
  defp decode(<<?X, text::binary>>), do: {:error, text}
end
