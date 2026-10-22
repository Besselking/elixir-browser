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

  @doc "The canvas ops of the small picture on a field that opens a picker: `:calendar` and `:clock`."
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

  def icon_ops(:clock, w, h) do
    k = min(w, h) / 16
    dark = {:color, {95, 99, 104, 255}}
    white = {:color, {255, 255, 255, 255}}
    tau = 2 * :math.pi()

    Canvas.new(max(trunc(w), 1), max(trunc(h), 1))
    |> Canvas.begin_path()
    |> Canvas.arc(8 * k, 8 * k, 7 * k, 0.0, tau, false)
    |> Canvas.fill(dark, :nonzero, 1.0)
    |> Canvas.begin_path()
    |> Canvas.arc(8 * k, 8 * k, 5.4 * k, 0.0, tau, false)
    |> Canvas.fill(white, :nonzero, 1.0)
    |> Canvas.fill_rect(7.4 * k, 4 * k, 1.2 * k, 4.6 * k, dark, 1.0)
    |> Canvas.fill_rect(7.4 * k, 7.4 * k, 3.6 * k, 1.2 * k, dark, 1.0)
    |> Canvas.ops()
  end

  @doc "The ops of a `<progress>` or `<meter>` bar (see `Browser.Forms.meter_bar/2`)."
  def bar_ops(spec, w, h) do
    track = {:color, {239, 239, 239, 255}}
    edge = {:color, {118, 118, 118, 255}}
    r = h / 2
    radii = [r, r, r, r]

    surface =
      Canvas.new(max(trunc(w), 1), max(trunc(h), 1))
      |> Canvas.begin_path()
      |> Canvas.round_rect(0, 0, w, h, radii)
      |> Canvas.fill(track, :nonzero, 1.0)

    {frac, color} =
      case spec do
        {:progress, nil} -> {0.0, nil}
        {:progress, f} -> {f, {0, 117, 255, 255}}
        {:meter, f, :good} -> {f, {16, 166, 66, 255}}
        {:meter, f, :warn} -> {f, {255, 194, 0, 255}}
        {:meter, f, :bad} -> {f, {230, 57, 53, 255}}
      end

    surface =
      if color && frac > 0 do
        surface
        |> Canvas.begin_path()
        |> fill_shape(max(w * frac, 1.0), w, h)
        |> Canvas.fill({:color, color}, :nonzero, 1.0)
      else
        surface
      end

    surface
    |> Canvas.begin_path()
    |> Canvas.round_rect(0.5, 0.5, w - 1, h - 1, [r, r, r, r])
    |> Canvas.stroke(edge, %{width: 1.0, cap: :butt, join: :miter, miter: 10.0}, 1.0)
    |> Canvas.ops()
  end

  # The part of a bar (a rounded track `w` x `h`) that is left of `fw`: the end caps are
  # half circles, so the path follows them where the fill reaches into one.
  defp fill_shape(surface, fw, w, h) when fw >= w - 0.5 do
    surface |> Canvas.round_rect(0, 0, w, h, List.duplicate(h / 2, 4))
  end

  defp fill_shape(surface, fw, _w, h) when fw <= h / 2 do
    r = h / 2
    beta = :math.acos((fw - r) / r)
    surface |> Canvas.arc(r, r, r, beta, 2 * :math.pi() - beta, false) |> Canvas.close_path()
  end

  defp fill_shape(surface, fw, w, h) do
    r = h / 2
    pi = :math.pi()
    left = Canvas.arc(surface, r, r, r, pi / 2, 3 * pi / 2, false)

    if fw <= w - r do
      left |> Canvas.line_to(fw, 0) |> Canvas.line_to(fw, h) |> Canvas.close_path()
    else
      cap = :math.acos((fw - (w - r)) / r)

      left
      |> Canvas.line_to(w - r, 0)
      |> Canvas.arc(w - r, r, r, -pi / 2, -cap, false)
      |> Canvas.line_to(fw, r + r * :math.sin(cap))
      |> Canvas.arc(w - r, r, r, cap, pi / 2, false)
      |> Canvas.close_path()
    end
  end

  defp bar(surface, _x, _cy, w, _color) when w <= 0, do: surface

  defp bar(surface, x, cy, w, color) do
    surface
    |> Canvas.begin_path()
    |> Canvas.round_rect(x, cy - 2, w, 4, [2, 2, 2, 2])
    |> Canvas.fill({:color, color}, :nonzero, 1.0)
  end
end
