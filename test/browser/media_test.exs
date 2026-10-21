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

  describe "Player" do
    alias Browser.Media.Player

    defp player(clip) do
      url = "file://" <> clip
      {:ok, pid} = Player.start(url: url, base: url, owner: self())
      {pid, url}
    end

    defp frames(url, ms) do
      receive do
        {:media_frame, _pid, ^url, <<"BM", _::binary>>} ->
          [:frame | frames(url, ms)]
      after
        ms -> []
      end
    end

    test "it plays the frames in time, then goes back to the first frame", %{clip: clip} do
      {pid, url} = player(clip)
      assert_receive {:media_state, _pid, ^url, :ready, _}, 5000
      Player.play(pid)
      assert_receive {:media_state, _pid, ^url, :playing, _}, 1000
      started = System.monotonic_time(:millisecond)
      assert_receive {:media_state, _pid, ^url, :ended, _}, 5000
      took = System.monotonic_time(:millisecond) - started
      # 20 frames at 10 per second
      assert took in 1500..3500
      # (the frames, and the first one again at the end)
      assert length(frames(url, 200)) in 19..22
      assert Player.status(pid) == :paused
      assert Player.position(pid) == 0
    end

    test "pause stops the frames and play goes on", %{clip: clip} do
      {pid, url} = player(clip)
      assert_receive {:media_state, _pid, ^url, :ready, _}, 5000
      Player.play(pid)
      Process.sleep(500)
      Player.pause(pid)
      assert_receive {:media_state, _pid, ^url, :paused, _}, 1000
      _ = frames(url, 100)
      assert frames(url, 400) == []
      pos = Player.position(pid)
      assert pos > 0
      Player.toggle(pid)
      assert_receive {:media_frame, ^pid, ^url, _}, 1000
      assert Player.position(pid) >= pos
    end

    test "seek_fraction shows the frame at that place", %{clip: clip} do
      {pid, url} = player(clip)
      assert_receive {:media_state, _pid, ^url, :ready, %{duration_ms: duration}}, 5000
      Player.seek_fraction(pid, 0.5)
      assert_receive {:media_state, _pid, ^url, :seeked, %{pos: pos}}, 2000
      assert_receive {:media_frame, ^pid, ^url, <<"BM", _::binary>>}, 1000
      assert abs(pos - duration / 2) < 400
      assert Player.status(pid) == :paused
    end

    test "seek_ms shows the frame at that time", %{clip: clip} do
      {pid, url} = player(clip)
      assert_receive {:media_state, _pid, ^url, :ready, _}, 5000
      Player.seek_ms(pid, 1000)
      assert_receive {:media_state, _pid, ^url, :seeked, %{pos: pos}}, 2000
      assert abs(pos - 1000) < 300
    end

    test "a video with loop starts again instead of ending", %{clip: clip} do
      url = "file://" <> clip
      {:ok, pid} = Player.start(url: url, base: url, owner: self(), loop: true)
      assert_receive {:media_state, _pid, ^url, :ready, _}, 5000
      Player.play(pid)
      Process.sleep(3500)
      refute_received {:media_state, _pid, ^url, :ended, _}
      assert Player.status(pid) == :playing
      Player.pause(pid)
    end

    test "a file that cannot be played fails", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.mp4")
      File.write!(path, "junk")
      {_pid, url} = player(path)
      assert_receive {:media_state, _pid, ^url, :failed, _}, 5000
    end
  end
end
