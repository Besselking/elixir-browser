defmodule Browser.MediaTest do
  use ExUnit.Case, async: true

  alias Browser.Media

  # needs the helper (mix media.build) and the ffmpeg program to make a clip
  @ready Media.available?() and System.find_executable("ffmpeg") != nil
  unless @ready, do: @moduletag(skip: "the media helper or ffmpeg is missing")

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    clip = Path.join(dir, "clip.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-loglevel error -y -f lavfi -i testsrc=size=160x120:rate=10:duration=2
           -f lavfi -i sine=frequency=440:duration=2 -c:v mpeg4 -c:a aac -shortest) ++ [clip]
      )

    {:ok, clip: clip}
  end

  test "open tells the size, duration and streams", %{clip: clip} do
    assert {:ok, media} = Media.open(clip)
    assert %{width: 160, height: 120, video?: true, audio?: true, fps: fps} = media.info
    assert_in_delta fps, 10.0, 0.01
    assert media.info.duration_ms in 1900..2200
    assert media.info.video_codec == "mpeg4"
    Media.close(media)
  end

  test "video frames come in order, scaled to the size asked for", %{clip: clip} do
    {:ok, media} = Media.open(clip)
    {:ok, media} = Media.set_size(media, 80, 60)
    assert {:frame, 0, 80, 60, rgba} = Media.next_video(media)
    assert byte_size(rgba) == 80 * 60 * 4
    assert {:frame, pts, 80, 60, _} = Media.next_video(media)
    assert pts in 90..110
    Media.close(media)
  end

  test "all the frames, then :end", %{clip: clip} do
    {:ok, media} = Media.open(clip)

    frames =
      Stream.repeatedly(fn -> Media.next_video(media) end)
      |> Enum.take_while(&match?({:frame, _, _, _, _}, &1))

    assert length(frames) == 20
    assert Media.next_video(media) == :end
    Media.close(media)
  end

  test "audio chunks are s16 stereo at 48000 Hz", %{clip: clip} do
    {:ok, media} = Media.open(clip)
    assert {:audio, 0, pcm} = Media.next_audio(media)
    assert rem(byte_size(pcm), 4) == 0 and byte_size(pcm) > 0

    total =
      Stream.repeatedly(fn -> Media.next_audio(media) end)
      |> Enum.take_while(&match?({:audio, _, _}, &1))
      |> Enum.reduce(byte_size(pcm), fn {:audio, _, p}, n -> n + byte_size(p) end)

    # about two seconds of audio
    assert_in_delta total / 4 / 48_000, 2.0, 0.15
    Media.close(media)
  end

  test "video and audio can be read in any order", %{clip: clip} do
    {:ok, media} = Media.open(clip)
    for _ <- 1..5, do: assert({:audio, _, _} = Media.next_audio(media))
    assert {:frame, 0, 160, 120, _} = Media.next_video(media)
    Media.close(media)
  end

  test "seek skips the frames before the time", %{clip: clip} do
    {:ok, media} = Media.open(clip)
    assert :ok = Media.seek(media, 1000)
    assert {:frame, pts, _, _, _} = Media.next_video(media)
    assert pts >= 1000 and pts < 1200
    assert {:audio, apts, _} = Media.next_audio(media)
    assert apts >= 950
    Media.close(media)
  end

  test "bmp frames are whole BMP files", %{clip: clip} do
    {:ok, media} = Media.open(clip)
    {:ok, media} = Media.set_format(media, :bmp)
    assert {:frame, 0, 160, 120, bmp} = Media.next_video(media)
    assert <<"BM", size::32-little, _::binary>> = bmp
    assert size == byte_size(bmp)
    assert byte_size(bmp) == 54 + 160 * 3 * 120
    Media.close(media)
  end

  test "first_frame gives a BMP and its size, scaled to a width", %{clip: clip} do
    bytes = File.read!(clip)
    assert {:ok, <<"BM", _::binary>>, {160, 120}} = Media.first_frame(bytes)
    assert {:ok, <<"BM", _::binary>>, {80, 60}} = Media.first_frame(bytes, 80)
    assert {:error, _} = Media.first_frame("not a video")
  end

  test "a file that is no media gives an error", %{tmp_dir: dir} do
    path = Path.join(dir, "junk.mp4")
    File.write!(path, String.duplicate("not a video", 100))
    assert {:error, _text} = Media.open(path)
  end

  test "a missing file gives an error" do
    assert {:error, _} = Media.open("/nonexistent/clip.mp4")
  end
end
