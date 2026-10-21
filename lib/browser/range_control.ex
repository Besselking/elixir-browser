defmodule Browser.RangeControl do
  @moduledoc """
  The picture of an `<input type=range>`: a track with the part up to the thumb filled, and a
  round thumb. The layout draws it at the size of the control (see `Browser.Forms`: the control
  holds a canvas with a `"@range"` attribute), and `Browser.Session` moves the thumb when the
  mouse or the keys change the value.
  """

  alias Browser.Canvas

  @thumb 7
  @blue {0, 117, 255, 255}

  @doc "The horizontal room the thumb needs on each side of the track."
  def margin, do: @thumb

  @doc "The place of the thumb along a control of width `w` that holds `frac` (0.0 to 1.0)."
  def thumb_x(w, frac), do: @thumb + (w - 2 * @thumb) * frac

  @doc "The value fraction for a click at `dx` px from the left edge of a control `w` px wide."
  def frac_at(dx, w), do: min(max((dx - @thumb) / max(w - 2 * @thumb, 1), 0.0), 1.0)

  @doc "The canvas ops of a `w` x `h` range with the thumb at `frac`."
  def ops(w, h, {frac, disabled?}) do
    {track, fill, thumb} =
      if disabled?,
        do: {{225, 227, 231, 255}, {170, 174, 182, 255}, {170, 174, 182, 255}},
        else: {{200, 204, 212, 255}, @blue, @blue}

    cy = h / 2
    x = thumb_x(w, frac)

    Canvas.new(max(trunc(w), 1), max(trunc(h), 1))
    |> bar(@thumb, cy, w - 2 * @thumb, track)
    |> bar(@thumb, cy, x - @thumb, fill)
    |> Canvas.begin_path()
    |> Canvas.arc(x, cy, @thumb, 0, 2 * :math.pi(), false)
    |> Canvas.close_path()
    |> Canvas.fill({:color, thumb}, :nonzero, 1.0)
    |> Canvas.ops()
  end

  @doc "The canvas ops of the small picture on a field that opens a picker: `:calendar`."
  def icon_ops(:calendar, w, h) do
    k = min(w, h) / 16
    dark = {:color, {95, 99, 104, 255}}
    white = {:color, {255, 255, 255, 255}}

    surface =
      Canvas.new(max(trunc(w), 1), max(trunc(h), 1))
      |> Canvas.begin_path()
      |> Canvas.round_rect(1 * k, 2 * k, 14 * k, 13 * k, [2 * k, 2 * k, 2 * k, 2 * k])
      |> Canvas.fill(dark, :nonzero, 1.0)
      |> Canvas.fill_rect(2 * k, 6 * k, 12 * k, 8 * k, white, 1.0)

    for {x, y} <- [{4, 8}, {7, 8}, {10, 8}, {4, 11}, {7, 11}], reduce: surface do
      acc -> Canvas.fill_rect(acc, x * k, y * k, 2 * k, 2 * k, dark, 1.0)
    end
    |> Canvas.ops()
  end

  defp bar(surface, _x, _cy, w, _color) when w <= 0, do: surface

  defp bar(surface, x, cy, w, color) do
    surface
    |> Canvas.begin_path()
    |> Canvas.round_rect(x, cy - 2, w, 4, [2, 2, 2, 2])
    |> Canvas.fill({:color, color}, :nonzero, 1.0)
  end
end
