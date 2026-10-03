defmodule Browser.Screenshot do
  @moduledoc """
  Draws a laid-out page as SVG without a window, for screenshots from machines that have no
  display (see `mix browser.screenshot`). Text is measured with a fixed advance per
  character and drawn squeezed to that width, so the layout is the browser's own but the
  glyphs are whatever font the SVG viewer picks. Pictures, vector graphics and shadows are
  left out.
  """

  @doc "Measures text the way `svg/4` draws it: a fixed advance per character."
  def measure(text, %{size: size} = style) do
    advance = if Map.get(style, :mono), do: 0.6, else: 0.52
    round(String.length(text) * size * advance)
  end

  @doc "The SVG for `items` (from `Browser.Layout.layout/5`) on a `width` x `height` canvas."
  def svg(items, width, height, opts \\ []) do
    canvas = Enum.find_value(items, {255, 255, 255}, &(&1.type == :canvas && &1.color))
    {body, _} = Enum.map_reduce(items, 0, fn item, n -> {draw(item, n), n + 1} end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" #{opts[:attrs]}>
    <rect width="100%" height="100%" fill="#{fill(canvas)}"/>
    #{body}
    </svg>
    """
  end

  defp draw(%{type: :rect, radius: radius} = r, n) when radius != nil do
    {mask_def, mask_attr} = mask(r, n)

    fill =
      if r.color,
        do: ~s|<path d="#{outline(r.x, r.y, r.w, r.h, radius)}" #{fill_attr(r.color)}/>|,
        else: ""

    mask_def <> fill <> border(r, n, mask_attr)
  end

  defp draw(%{type: :rect, color: color} = r, _n) when color != nil,
    do: ~s|<rect x="#{r.x}" y="#{r.y}" width="#{r.w}" height="#{r.h}" #{fill_attr(color)}/>\n|

  defp draw(%{type: :hr} = h, _n),
    do: ~s|<rect x="#{h.x}" y="#{h.y}" width="#{h.w}" height="1" fill="#aaa"/>\n|

  defp draw(%{type: :text} = t, _n) do
    base = t.y + round(t.h * 0.8)
    family = if t.mono, do: "monospace", else: "sans-serif"

    attrs =
      "font-family=\"#{family}\" font-size=\"#{t.size}\" textLength=\"#{measure(t.text, t)}\" " <>
        "lengthAdjust=\"spacingAndGlyphs\" xml:space=\"preserve\" " <>
        "fill=\"#{fill(t.color)}\"" <>
        if(t.bold, do: ~s| font-weight="bold"|, else: "") <>
        if(t.italic, do: ~s| font-style="italic"|, else: "") <>
        if(t.underline, do: ~s| text-decoration="underline"|, else: "")

    ~s|<text x="#{t.x}" y="#{base}" #{attrs}>#{escape(t.text)}</text>\n|
  end

  # a picture: its place, since pictures are not decoded here
  defp draw(%{type: :image} = i, _n),
    do:
      ~s|<rect x="#{i.x}" y="#{i.y}" width="#{i.w}" height="#{i.h}" fill="#eee" stroke="#ccc"/>\n|

  defp draw(_item, _n), do: ""

  # -- borders ---------------------------------------------------------------------------

  defp border(%{border: nil}, _n, _mask), do: ""

  defp border(%{border: %{w: {bt, br, bb, bl}, c: {tc, rc, bc, lc}} = b} = r, _n, mask) do
    {st, sr, sb, sl} = Map.get(b, :s) || {:solid, :solid, :solid, :solid}

    if bt == br and br == bb and bb == bl and tc == rc and rc == bc and bc == lc and
         st == sr and sr == sb and sb == sl do
      # one stroke along the middle of the border
      half = bt / 2

      d =
        outline(r.x + half, r.y + half, r.w - bt, r.h - bt, shrink(r.radius, half))

      ~s|<path d="#{d}" fill="none" stroke="#{fill(tc)}" stroke-width="#{bt}" #{dash(st, bt)} #{mask}/>\n|
    else
      for {w, c, rect} <- [
            {bt, tc, {r.x, r.y, r.w, bt}},
            {bb, bc, {r.x, r.y + r.h - bb, r.w, bb}},
            {bl, lc, {r.x, r.y, bl, r.h}},
            {br, rc, {r.x + r.w - br, r.y, br, r.h}}
          ],
          w > 0 and c != nil,
          {x, y, w2, h} = rect,
          into: "",
          do: ~s|<rect x="#{x}" y="#{y}" width="#{w2}" height="#{h}" fill="#{fill(c)}"/>\n|
    end
  end

  # the gap a fieldset's legend leaves in the top border
  defp mask(%{border: %{gap: {g0, g1}, w: {bt, _, _, _}}} = r, n) when bt > 0 do
    id = "gap#{n}"

    defs =
      ~s|<mask id="#{id}"><rect x="0" y="0" width="100%" height="100%" fill="#fff"/>| <>
        ~s|<rect x="#{g0}" y="#{r.y - 1}" width="#{g1 - g0}" height="#{bt + 2}" fill="#000"/></mask>\n|

    {defs, "mask=\"url(##{id})\""}
  end

  defp mask(_r, _n), do: {"", ""}

  defp dash(:dashed, t), do: ~s|stroke-dasharray="#{3 * t} #{3 * t}"|
  defp dash(:dotted, t), do: ~s|stroke-dasharray="#{t} #{t}"|
  defp dash(_, _t), do: ""

  defp shrink(radii, by) do
    radii
    |> Tuple.to_list()
    |> Enum.map(fn {a, b} -> {max(a - by, 0), max(b - by, 0)} end)
    |> List.to_tuple()
  end

  defp outline(x, y, w, h, {{tlx, tly}, {trx, try_}, {brx, bry}, {blx, bly}}) do
    "M#{x + tlx} #{y} H#{x + w - trx} A#{trx} #{try_} 0 0 1 #{x + w} #{y + try_} " <>
      "V#{y + h - bry} A#{brx} #{bry} 0 0 1 #{x + w - brx} #{y + h} " <>
      "H#{x + blx} A#{blx} #{bly} 0 0 1 #{x} #{y + h - bly} " <>
      "V#{y + tly} A#{tlx} #{tly} 0 0 1 #{x + tlx} #{y} Z"
  end

  # -- helpers ---------------------------------------------------------------------------

  defp fill_attr({r, g, b, a}),
    do: ~s|fill="rgb(#{r},#{g},#{b})" fill-opacity="#{a / 255}"|

  defp fill_attr(color), do: ~s|fill="#{fill(color)}"|

  defp fill({r, g, b}), do: "rgb(#{r},#{g},#{b})"
  defp fill({r, g, b, _a}), do: "rgb(#{r},#{g},#{b})"
  defp fill(_), do: "none"

  defp escape(s),
    do:
      s
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
end
