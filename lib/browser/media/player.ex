defmodule Browser.Media.Player do
  @moduledoc """
  Plays one video without sound (docs/media.md). It downloads the video to a file, opens it
  with `Browser.Media` and, while playing, sends the owner each frame in time:

      {:media_frame, player_pid, url, bmp_bytes}

  which the session turns into the message of a loaded picture (`"media:" <> url`), so the
  page draws the frame like an image. Other messages to the owner: `{:media_state, player_pid, url, what, snapshot}` with `what` one of `:ready | :playing | :paused | :time | :seeked | :ended | :failed` and a snapshot map of `:pos`, `:duration_ms`, `:width`, `:height`.

  A frame that comes too late (more than 200 ms) is not shown. At the end the player
  goes back to the first frame, paused.
  """

  use GenServer

  alias Browser.{Fetch, Media}

  @max_bytes 256 * 1024 * 1024
  @max_frame_width 1280
  @late_ms 200

  @doc "Starts a player (not linked: a failing player must not stop the session)."
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc "Starts or continues playing."
  def play(pid), do: GenServer.cast(pid, :play)

  @doc "Stops at the frame that is shown."
  def pause(pid), do: GenServer.cast(pid, :pause)

  @doc "Plays when paused, pauses when playing."
  def toggle(pid), do: GenServer.cast(pid, :toggle)

  @doc "Jumps to `fraction` (0.0 to 1.0) of the length and shows the frame there."
  def seek_fraction(pid, fraction), do: GenServer.cast(pid, {:seek_fraction, fraction})

  @doc "The state: `:loading | :paused | :playing | :failed`."
  def status(pid), do: GenServer.call(pid, :status)

  @doc "The time of the frame that is shown, in ms."
  def position(pid), do: GenServer.call(pid, :position)

  # -- server --------------------------------------------------------------------------

  # opts: :url (of the video), :base (the page's address), :owner
  @impl true
  def init(opts) do
    state = %{
      url: opts[:url],
      base: opts[:base],
      owner: opts[:owner],
      media: nil,
      status: :loading,
      want_play: false,
      pos: 0,
      held: nil,
      clock: nil,
      timer: nil,
      tu: 0
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    with {:ok, bytes} <- download(state),
         {:ok, media} <- open(bytes) do
      state = %{state | media: media, status: :paused}
      notify(state, :ready)
      {:noreply, if(state.want_play, do: begin_playing(state), else: state)}
    else
      _ ->
        notify(state, :failed)
        {:noreply, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:position, _from, state), do: {:reply, state.pos, state}

  @impl true
  def handle_cast(:play, state), do: {:noreply, do_play(state)}
  def handle_cast(:pause, state), do: {:noreply, do_pause(state)}
  def handle_cast(:toggle, %{status: :playing} = state), do: {:noreply, do_pause(state)}

  def handle_cast(:toggle, %{want_play: true, status: :loading} = state),
    do: {:noreply, do_pause(state)}

  def handle_cast(:toggle, state), do: {:noreply, do_play(state)}

  def handle_cast({:seek_fraction, _}, %{media: nil} = state), do: {:noreply, state}

  def handle_cast({:seek_fraction, fraction}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    playing? = state.status == :playing
    ms = round(min(max(fraction, 0.0), 1.0) * (state.media.info[:duration_ms] || 0))
    state = %{state | timer: nil, held: nil, clock: nil}

    with :ok <- Media.seek(state.media, ms),
         {:frame, pts, _, _, bmp} <- Media.next_video(state.media) do
      send(state.owner, {:media_frame, self(), state.url, bmp})
      state = %{state | pos: pts, tu: pts}
      notify(state, :seeked)
      {:noreply, if(playing?, do: next_frame(state), else: state)}
    else
      _ -> {:noreply, state}
    end
  end

  # a decoded frame is due: show it, then decode the next one
  @impl true
  def handle_info({:show, {pts, bmp}}, %{status: :playing} = state) do
    send(state.owner, {:media_frame, self(), state.url, bmp})
    state = %{state | pos: pts, held: nil, timer: nil}

    # `timeupdate` about every 250 ms
    state =
      if pts - state.tu >= 250 or pts < state.tu do
        notify(state, :time)
        %{state | tu: pts}
      else
        state
      end

    {:noreply, next_frame(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{media: media}) when media != nil, do: Media.close(media)
  def terminate(_reason, _state), do: :ok

  # -- playing -------------------------------------------------------------------------

  defp do_play(%{status: :loading} = state), do: %{state | want_play: true}
  defp do_play(%{status: s} = state) when s in [:playing, :failed], do: state
  defp do_play(state), do: begin_playing(state)

  defp begin_playing(state) do
    notify(state, :playing)
    state = %{state | status: :playing, want_play: true}

    case state.held do
      # a frame that was decoded before the pause is the first one to show
      {pts, _bmp} = frame -> schedule(%{state | clock: {now(), pts}}, frame, 0)
      nil -> next_frame(%{state | clock: nil})
    end
  end

  defp do_pause(%{status: :playing} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    notify(state, :paused)
    %{state | status: :paused, want_play: false, timer: nil}
  end

  defp do_pause(state), do: %{state | want_play: false}

  # decode the next frame and show it at its time
  defp next_frame(state) do
    case Media.next_video(state.media) do
      {:frame, pts, _w, _h, bmp} ->
        {start, base_pts} = state.clock || {now(), pts}
        state = %{state | clock: {start, base_pts}}
        due = start + (pts - base_pts)

        if now() - due > @late_ms do
          # behind: drop the frame and start the clock again from the next one
          next_frame(%{state | clock: nil})
        else
          schedule(state, {pts, bmp}, max(due - now(), 0))
        end

      :end ->
        finish(state)

      {:error, _} ->
        notify(state, :failed)
        %{state | status: :failed}
    end
  end

  defp schedule(state, frame, delay) do
    %{state | held: frame, timer: Process.send_after(self(), {:show, frame}, delay)}
  end

  # back to the first frame, paused
  defp finish(state) do
    notify(state, :ended)
    state = %{state | status: :paused, want_play: false, held: nil, clock: nil, timer: nil}

    with :ok <- Media.seek(state.media, 0),
         {:frame, pts, _, _, bmp} <- Media.next_video(state.media),
         :ok <- Media.seek(state.media, 0) do
      send(state.owner, {:media_frame, self(), state.url, bmp})
      %{state | pos: pts}
    else
      _ -> state
    end
  end

  # -- loading -------------------------------------------------------------------------

  defp download(state) do
    case Fetch.load(state.url, initiator: state.base) do
      {:ok, bytes, _final} when byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      {:ok, _, _} -> {:error, :too_large}
      error -> error
    end
  end

  defp open(bytes) do
    path = Path.join(System.tmp_dir!(), "browser-play-#{System.unique_integer([:positive])}")

    try do
      File.write!(path, bytes)

      with {:ok, media} <- Media.open(path),
           true <- media.info.video? or {:error, :no_video},
           {:ok, media} <- Media.set_format(media, :bmp) do
        width = media.info.width

        if width > @max_frame_width do
          Media.set_size(
            media,
            @max_frame_width,
            div(media.info.height * @max_frame_width, width)
          )
        else
          {:ok, media}
        end
      end
    after
      # the helper has the file open: it can go
      File.rm(path)
    end
  end

  # what the owner (and so the page's scripts) can read: the time, the length, the picture size
  defp notify(state, what) do
    info = if state.media, do: state.media.info, else: %{}

    snapshot = %{
      pos: state.pos,
      duration_ms: info[:duration_ms],
      width: info[:width],
      height: info[:height]
    }

    send(state.owner, {:media_state, self(), state.url, what, snapshot})
  end

  defp now, do: System.monotonic_time(:millisecond)
end
