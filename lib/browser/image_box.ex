defmodule Browser.ImageBox do
  @moduledoc """
  The size of an image's content box, following the rules for replaced elements.

  `size(intrinsic, attrs, css, avail)` takes

    * `intrinsic`: `{width, height}` of the picture, or nil while it is unknown
    * `attrs`: the `width`/`height` attributes, `%{w: n | nil, h: n | nil}`
    * `css`: computed `width`, `height`, `min-*` and `max-*`, as
      `%{w:, h:, minw:, maxw:, minh:, maxh:}` with px numbers, `{:pct, fraction}`
      or nil
    * `avail`: the container's content width, which percentages refer to

  CSS wins over attributes, and `:auto` (a declared `width: auto`) ignores them. With only one dimension given the other follows the
  aspect ratio (from the picture, else from the attributes); with none the
  intrinsic size is used. Percentage heights are ignored. The min/max limits
  then apply, and an automatic dimension keeps the aspect ratio when the other
  one is limited.
  """

  @spec size({number, number} | nil, map, map, number) :: {non_neg_integer, non_neg_integer}
  def size(intrinsic, attrs, css, avail) do
    ratio = ratio(intrinsic, attrs)
    wspec = spec(css[:w], width(css[:w], avail), attrs[:w])
    hspec = spec(css[:h], px(css[:h]), attrs[:h])

    {w, h} =
      case {wspec, hspec} do
        {nil, nil} -> intrinsic || {0, 0}
        {w, nil} -> {w, derive(w, ratio, :height, intrinsic)}
        {nil, h} -> {derive(h, ratio, :width, intrinsic), h}
        {w, h} -> {w, h}
      end

    {w, h} = limit_width(w, h, hspec, ratio, css, avail)
    {w, h} = limit_height(w, h, wspec, ratio, css)
    {round(max(w, 0)), round(max(h, 0))}
  end

  # CSS wins over the attributes; an explicit `auto` switches the attribute off
  defp spec(:auto, _css, _attr), do: nil
  defp spec(_declared, css, attr), do: css || attr

  defp ratio({iw, ih}, _attrs) when iw > 0 and ih > 0, do: iw / ih
  defp ratio(_, %{w: w, h: h}) when is_number(w) and is_number(h) and w > 0 and h > 0, do: w / h
  defp ratio(_, _), do: nil

  # the other dimension, from the aspect ratio if there is one
  defp derive(known, ratio, :height, _intrinsic) when is_number(ratio), do: known / ratio
  defp derive(known, ratio, :width, _intrinsic) when is_number(ratio), do: known * ratio

  defp derive(_known, _ratio, :height, intrinsic),
    do: if(intrinsic, do: elem(intrinsic, 1), else: 0)

  defp derive(_known, _ratio, :width, intrinsic),
    do: if(intrinsic, do: elem(intrinsic, 0), else: 0)

  defp limit_width(w, h, hspec, ratio, css, avail) do
    maxw = width(css[:maxw], avail)
    minw = width(css[:minw], avail)

    {w2, changed?} =
      cond do
        maxw && w > maxw -> {maxw, true}
        minw && w < minw -> {minw, true}
        true -> {w, false}
      end

    h2 = if changed? and hspec == nil and ratio, do: w2 / ratio, else: h
    {w2, h2}
  end

  defp limit_height(w, h, wspec, ratio, css) do
    maxh = px(css[:maxh])
    minh = px(css[:minh])

    {h2, changed?} =
      cond do
        maxh && h > maxh -> {maxh, true}
        minh && h < minh -> {minh, true}
        true -> {h, false}
      end

    w2 = if changed? and wspec == nil and ratio, do: h2 * ratio, else: w
    {w2, h2}
  end

  defp width({:pct, f}, avail), do: f * avail
  defp width(n, _avail) when is_number(n), do: n
  defp width(_, _avail), do: nil

  # percentage heights depend on the container's height, which is not known: ignored
  defp px(n) when is_number(n), do: n
  defp px(_), do: nil
end
