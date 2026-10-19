defmodule Browser.LayoutBigAtomTest do
  use ExUnit.Case, async: true
  alias Browser.{Layout, Page}

  # An atom (an inline-block, a cell, a flex container, ...) with 200 items or more does not
  # change its items when it is put on its line. They wait in one entry and are changed when
  # they are taken apart, and a box that clips them makes only the items it keeps. An atom with
  # fewer items changes them at once. These tests lay out the same atom with a few words and
  # with many: the items the two have in common must be the same.

  defp measure(text, style), do: String.length(text) * div(round(style.size), 2)

  defp layout(html, opts \\ []) do
    page = Page.build(html, "about:test")
    opts = [images: %{}, svg_defs: page.svg_defs, boxes: true] ++ opts
    {items, _height} = Layout.layout(page.nodes, 600, &measure/2, 600, opts)
    items
  end

  defp words(n), do: Enum.map_join(1..n, " ", &"w#{&1}")

  # the items without the words after the first `k` (the ones only the big atom has)
  defp first_words(items, k), do: Enum.reject(items, &later_word?(&1, k))

  defp later_word?(%{type: :text, text: "w" <> n}, k), do: String.to_integer(n) > k
  defp later_word?(_item, _k), do: false

  # `html_of` gives a page with the words it is given at the end of the atom: with 5 words the
  # atom has fewer than 200 items, with 300 it has more
  defp same_small_and_big!(html_of) do
    small = layout(html_of.(words(5)))
    big = layout(html_of.(words(300)))
    assert length(small) < 200
    assert Layout.memo_norm(first_words(big, 5)) == Layout.memo_norm(small)
    big
  end

  # what moves differently from a plain word: a sticky box, a transform, a shadow and a
  # gradient (layers), a fieldset (the gap of its legend), boxes that clip and scroll, paint
  # orders (z-index, outline), and an inline-block narrower than its word (its own extent limit)
  @kids """
  <div style="position:sticky;top:0;background:yellow">sticky</div>
  <span style="position:relative;top:3px;left:2px;z-index:1">rel one two</span>
  <div style="position:relative;z-index:2;background:#ddd">above</div>
  <div style="position:relative;z-index:-1;background:#ccc">under</div>
  <div style="transform:translate(5px,6px) rotate(10deg)">turned</div>
  <div style="overflow:hidden;height:20px;background:pink">clipped a b c d e f g h i j k l m n o p q r s t u v</div>
  <div style="overflow:auto;height:20px">scrolled a b c d e f g h i j k l m n o p q r s t u v</div>
  <a href="#q" style="outline:2px solid blue">outlined</a>
  <div style="box-shadow:2px 2px 4px black, inset 0 0 3px red;border-radius:4px;border:2px solid green">shadow</div>
  <fieldset><legend>legend</legend>fieldset</fieldset>
  <div style="background-image:linear-gradient(red,blue);height:10px"></div>
  <span style="display:inline-block;width:40px">overflowing</span>
  """

  defp inline_block(content, style \\ ""),
    do:
      ~s(<div style="display:inline-block;width:300px;height:3000px;vertical-align:top;background:#eee;#{style}">) <>
        @kids <> content <> "</div>"

  test "the items of a big inline-block are placed as those of a small one" do
    # (the padding on the right is room each item keeps free: `rr`)
    big =
      same_small_and_big!(fn words ->
        ~s(<div style="padding-right:30px"><div>pre #{inline_block(words)} post</div></div>)
      end)

    # the last word stops counting for the width of the content at the right edge of the
    # inline-block, and keeps the padding around it free on its right
    last = Enum.find(big, &match?(%{text: "w300"}, &1))
    box = Enum.find(big, &match?(%{type: :rect, color: {238, 238, 238}}, &1))
    assert last.xlim == box.x + box.w
    # (the padding and the margin of the body)
    assert last.rr == 30 + 8
  end

  test "a big inline-block in a box that clips it keeps the same items" do
    html = fn overflow, words ->
      ~s(<div style="overflow:#{overflow};height:150px;position:relative"><div>pre #{inline_block(words)} post</div><p>after</p></div>)
    end

    big = same_small_and_big!(&html.("hidden", &1))

    # (the words below the bottom of the box are dropped; each element keeps its bounds, for the
    # scripts)
    refute Enum.any?(big, &match?(%{type: :text, text: "w" <> _}, &1))
    bounds = fn items -> Enum.count(items, &(&1.type == :bounds)) end
    assert bounds.(big) == bounds.(layout(html.("visible", words(300))))
  end

  test "an inline-block of about 200 items gives the same items on both sides of 200" do
    # (the inline-block holds its words and nothing else: from 200 words on, they wait)
    html = fn n ->
      ~s(<div>pre <div style="display:inline-block;width:300px;height:3000px;vertical-align:top">#{words(n)}</div> post</div>)
    end

    small = html.(150) |> layout() |> Layout.memo_norm()

    for n <- 195..205 do
      assert html.(n) |> layout() |> first_words(150) |> Layout.memo_norm() == small
    end
  end

  test "a big inline-block in a relatively positioned inline moves with it" do
    big =
      same_small_and_big!(fn words ->
        ~s(<div>pre <span style="position:relative;top:4px;left:5px">in #{inline_block(words)}</span> post</div>)
      end)

    assert %{over: true} = Enum.find(big, &match?(%{text: "w300"}, &1))
  end

  # (what a cell paints behind its text goes with the backgrounds of the blocks, under the text
  # placed before it)
  test "a big table cell paints its background with the backgrounds of the blocks" do
    same_small_and_big!(fn words ->
      ~s(<div style="background:#fee"><p>earlier</p><div>pre <div style="display:table-cell;width:300px;height:3000px;vertical-align:top;background:#eee">#{@kids}#{words}</div> post</div></div>)
    end)
  end

  test "a big sticky inline-block is limited by the block it sits in" do
    same_small_and_big!(fn words ->
      ~s(<div style="height:4000px"><div>pre #{inline_block(words, "position:sticky;top:0")} post</div></div>)
    end)
  end

  test "the items of a big flex container still count for its width" do
    same_small_and_big!(fn words ->
      ~s(<div style="display:flex;height:3000px;padding-right:20px"><div style="width:300px">#{@kids}#{words}</div><div>side</div></div>)
    end)
  end

  test "a big inline-block in a big inline-block" do
    same_small_and_big!(fn words ->
      inner =
        ~s(<span style="display:inline-block;width:200px;height:2000px;vertical-align:top">#{words}</span>)

      ~s(<div style="overflow:hidden;height:400px"><div>pre #{inline_block(inner)} post</div></div>)
    end)
  end

  # The shape of the editor of the TipTap page of Speedometer: a box that clips, a flex row, a
  # flex column, a box that scrolls and a relatively positioned block of words that keep their
  # spaces (each space is an item). `extra` comes before the words.
  defp editor(extra, words, item_style) do
    ~s(<div style="position:absolute;left:10px;top:10px;width:500px;height:300px;overflow:hidden">) <>
      ~s(<div style="display:flex;height:400px">) <>
      ~s(<div style="display:flex;flex-direction:column;flex:1 1 0%;#{item_style}">) <>
      ~s(<div>toolbar</div><div style="overflow:auto;flex:1 1 0%">) <>
      ~s(<div style="position:relative;white-space:break-spaces;height:3000px">) <>
      extra <>
      words <>
      "</div>" <>
      "</div></div></div></div>"
  end

  # (a flex item of 8 items or more is moved in one entry: with a negative `z-index`, what it
  # paints behind the text still goes behind the text of the line, as for a small atom)
  test "the backgrounds of flex items with a negative z-index in a big flex row paint behind its text" do
    item =
      &~s(<div style="z-index:-1;flex:none;width:100px;background:#ddd;border:1px solid">i#{&1} a b c d e f</div>)

    same_small_and_big!(fn words ->
      ~s(<div style="display:flex;align-items:flex-start">) <>
        Enum.map_join(1..4, item) <>
        ~s(<div style="flex:1;min-width:0;height:3000px">#{words}</div></div>)
    end)
  end

  test "the items of a big editor in flex boxes are placed as those of a small one" do
    extras = [
      "",
      ~s(<span style="position:relative;z-index:3;top:2px">raised</span> ),
      ~s(<a href="#q" style="outline:2px solid blue">outlined</a> ),
      ~s(<div style="position:sticky;top:0;background:yellow">sticky</div>),
      ~s(<div style="position:absolute;top:5px;left:5px">absolute</div>),
      ~s(<span style="display:inline-block;background:#eee;width:50px">inline</span> )
    ]

    # (a flex item with a `z-index` paints with the positioned boxes)
    cases = Enum.map(extras, &{&1, ""}) ++ [{"", "z-index:2"}, {"", "z-index:-1"}]

    for {extra, item_style} <- cases do
      # (the spaces after the fifth word are only in the big one)
      space? = &match?(%{type: :text, text: "\u00A0"}, &1)
      # (the check mode also makes sure that the entries each atom keeps are its items)
      small = layout(editor(extra, words(5), item_style), lazy: :check)
      big = layout(editor(extra, words(300), item_style), lazy: :check)
      assert length(small) < 200 and length(big) > 300

      assert Layout.memo_norm(big |> Enum.reject(space?) |> first_words(5)) ==
               Layout.memo_norm(Enum.reject(small, space?))
    end
  end

  # (not only for big atoms: a clipping box works out where each item ends up before it makes
  # the item, and keeps it when it starts above its bottom)
  test "a box that clips keeps what a relative offset moves above its bottom" do
    html = fn top, height ->
      ~s(<body style="margin:0"><div style="overflow:hidden;height:#{height}px">) <>
        ~s(<div style="height:40px"></div>) <>
        ~s(<div style="position:relative;top:#{top}px">#{words(80)}</div></div>)
    end

    for top <- [-60, 30] do
      texts = fn items -> for %{type: :text} = t <- items, do: {t.text, t.y} end
      shown = html.(top, 2000) |> layout() |> texts.()
      assert html.(top, 100) |> layout() |> texts.() == for({_, y} = t <- shown, y < 100, do: t)
    end
  end
end
