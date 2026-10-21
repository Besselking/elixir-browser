defmodule Browser.Media.Controls do
  @moduledoc """
  The controls of a video with `controls`: a play button in the middle (paused only) and a
  bar with a play or pause button and a progress line along the bottom (docs/media.md).

  The layout draws them as an `:svg` item over the picture (`video_controls: true`). While the
  video plays, the session swaps the ops of that item (`apply/2`) when the state changes, so
  no new layout is needed.

  `ui` is `%{playing: bool, frac: 0.0..1.0, visible: bool}`; nil means paused at the start.
  """

  alias Browser.Canvas

  @bar 28
  @track_x 40
  @track_right 16

  @doc "The height of the bar and the places in it the clicks use: see `Browser.Session`."
  def bar, do: @bar
  def track_x, do: @track_x
  def track_right, do: @track_right

  @doc "The canvas ops of the controls of a `w` x `h` video."
  def ops(w, h, ui) do
    Canvas.new(max(trunc(w), 1), max(trunc(h), 1)) |> draw(w, h, ui) |> Canvas.ops()
  end

  @doc "Draws the controls onto `surface`."
  def draw(surface, w, h, ui) do
    ui = Map.merge(%{playing: false, frac: 0.0, visible: true}, ui || %{})
    if ui.visible, do: draw_visible(surface, w, h, ui), else: surface
  end

  defp draw_visible(surface, w, h, ui) do
    white = {:color, {255, 255, 255, 255}}
    track_w = max(w - @track_x - @track_right, 1)
    filled = track_w * min(max(ui.frac, 0.0), 1.0)

    surface =
      if ui.playing,
        do: surface,
        else: triangle(surface, w / 2 - 12, h / 2 - 16, 28, {:color, {255, 255, 255, 230}})

    surface
    |> Canvas.fill_rect(0, h - @bar, w, @bar, {:color, {0, 0, 0, 140}}, 1.0)
    |> button(h, ui.playing, white)
    |> Canvas.fill_rect(@track_x, h - 15, track_w, 3, {:color, {255, 255, 255, 140}}, 1.0)
    |> Canvas.fill_rect(@track_x, h - 15, filled, 3, white, 1.0)
    |> knob(@track_x + filled, h - 13.5, white)
  end

  # pause (two bars) while playing, play (a triangle) while paused
  defp button(surface, h, true, paint) do
    surface
    |> Canvas.fill_rect(11, h - 21, 4, 14, paint, 1.0)
    |> Canvas.fill_rect(19, h - 21, 4, 14, paint, 1.0)
  end

  defp button(surface, h, false, paint), do: triangle(surface, 10, h - 22, 16, paint)

  defp knob(surface, x, y, paint) do
    surface
    |> Canvas.begin_path()
    |> Canvas.arc(x, y, 5, 0, 2 * :math.pi(), false)
    |> Canvas.close_path()
    |> Canvas.fill(paint, :nonzero, 1.0)
  end

  @doc "A play triangle of height `size` with its top left corner at x, y."
  def triangle(surface, x, y, size, paint) do
    surface
    |> Canvas.begin_path()
    |> Canvas.move_to(x, y)
    |> Canvas.line_to(x + size * 0.9, y + size / 2)
    |> Canvas.line_to(x, y + size)
    |> Canvas.close_path()
    |> Canvas.fill(paint, :nonzero, 1.0)
  end

  @doc """
  The items with the controls of the videos in `states` (`%{element number => ui}`) drawn for
  that state.
  """
  def apply(items, states) when states == %{}, do: items

  def apply(items, states) do
    Enum.map(items, fn
      %{video_controls: true, nid: nid, w: w, h: h} = item when is_map_key(states, nid) ->
        %{item | ops: ops(w, h, states[nid])}

      item ->
        item
    end)
  end
end
