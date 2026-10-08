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
    ratio = ratio(intrinsic, attrs, css)
    wspec = spec(css[:w], width(css[:w], avail), width(attrs[:w], avail))
    hspec = spec(css[:h], px(css[:h]), px(attrs[:h]))

    {w, h} =
      case {wspec, hspec} do
        {nil, nil} -> intrinsic || {0, 0}
        {w, nil} -> {w, derive(w, ratio, :height, intrinsic)}
        {nil, h} -> {derive(h, ratio, :width, intrinsic), h}
        {w, h} -> {w, h}
      end

    {w, h} =
      if wspec == nil and hspec == nil and w > 0 and h > 0 do
        constrain(w, h, css, avail)
      else
        {w, h} = limit_width(w, h, hspec, ratio, css, avail)
        limit_height(w, h, wspec, ratio, css)
      end

    {round(max(w, 0)), round(max(h, 0))}
  end

  @doc """
  Where the picture goes in its content box for `object-fit` and `object-position`:
  `{dx, dy, w, h}`, the picture's own box relative to the content box (which clips it), or nil
  when the picture simply fills the box (`fill`, or no known size).
  """
  @spec fit({number, number} | nil, {number, number}, binary | nil, {term, term} | nil) ::
          {float, float, float, float} | nil
  def fit({iw, ih}, {cw, ch}, mode, pos) when iw > 0 and ih > 0 and cw > 0 and ch > 0 do
    scale =
      case mode do
        "contain" -> min(cw / iw, ch / ih)
        "cover" -> max(cw / iw, ch / ih)
        "none" -> 1.0
        "scale-down" -> min(1.0, min(cw / iw, ch / ih))
        _ -> nil
      end

    if scale do
      {w, h} = {iw * scale, ih * scale}
      {px, py} = pos || {{:pct, 0.5}, {:pct, 0.5}}
      {offset(px, cw - w), offset(py, ch - h), w, h}
    end
  end

  def fit(_, _, _, _), do: nil

  defp offset({:pct, f}, free), do: free * f
  defp offset(n, _free) when is_number(n), do: n * 1.0
  defp offset(_, free), do: free / 2

  @doc """
  True when `size/4` does not depend on the picture's own size: both dimensions are given
  by the attributes or by CSS, so the box is the same before and after the picture loads.
  """
  @spec fixed?(map, map) :: boolean
  def fixed?(attrs, css) do
    spec(css[:w], width(css[:w], 1), attrs[:w]) != nil and
      spec(css[:h], px(css[:h]), px(attrs[:h])) != nil
  end

  # CSS wins over the attributes; an explicit `auto` switches the attribute off
  defp spec(:auto, _css, _attr), do: nil
  defp spec(_declared, css, attr), do: css || attr

  # a declared `aspect-ratio` is the picture's ratio, unless it says `auto` and the picture has one
  defp ratio(intrinsic, attrs, css) do
    case css[:ratio] do
      {r, :sizing} when is_number(r) -> r
      {r, _} when is_number(r) -> ratio(intrinsic, attrs) || r
      _ -> ratio(intrinsic, attrs)
    end
  end

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

  # the table of CSS 2.1 section 10.4: a picture with neither width nor height keeps its ratio
  # when min and max sizes change it, whichever of them is broken
  defp constrain(w, h, css, avail) do
    maxw = width(css[:maxw], avail)
    minw = width(css[:minw], avail) || 0
    maxh = px(css[:maxh])
    minh = px(css[:minh]) || 0
    maxw = if maxw, do: max(maxw, minw)
    maxh = if maxh, do: max(maxh, minh)
    over_w = maxw != nil and w > maxw
    under_w = w < minw
    over_h = maxh != nil and h > maxh
    under_h = h < minh

    cap_w = fn v -> if maxw, do: min(maxw, v), else: v end
    cap_h = fn v -> if maxh, do: min(maxh, v), else: v end

    cond do
      over_w and under_h ->
        {maxw, minh}

      under_w and over_h ->
        {minw, maxh}

      over_w and over_h ->
        if maxw / w <= maxh / h,
          do: {maxw, max(minh, maxw * h / w)},
          else: {max(minw, maxh * w / h), maxh}

      under_w and under_h ->
        if minw / w <= minh / h,
          do: {cap_w.(minh * w / h), minh},
          else: {minw, cap_h.(minw * h / w)}

      over_w ->
        {maxw, max(minh, maxw * h / w)}

      under_w ->
        {minw, cap_h.(minw * h / w)}

      over_h ->
        {max(minw, maxh * w / h), maxh}

      under_h ->
        {cap_w.(minh * w / h), minh}

      true ->
        {w, h}
    end
  end

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
