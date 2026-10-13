defmodule Browser.LayoutMemoTest do
  use ExUnit.Case, async: true
  alias Browser.{Forms, Layout, Page}

  # A layout that starts from the memo of an earlier one must give what a fresh layout gives.

  defp measure(text, style), do: String.length(text) * div(round(style.size), 2)

  defp page(html), do: Page.build(html, "about:test")

  defp kept(page, memo, opts \\ [], width \\ 500, view_h \\ 600) do
    opts = Keyword.merge([images: %{}, svg_defs: page.svg_defs], opts)
    Layout.layout_kept(page.nodes, width, &measure/2, view_h, opts, memo)
  end

  # (the ops as a flat list: no spans, no fragments)
  defp fresh(page, opts, width, view_h),
    do: page |> kept(nil, [spans: false] ++ opts, width, view_h) |> Tuple.delete_at(2)

  defp same!(page, memo, opts \\ [], width \\ 500, view_h \\ 600) do
    {items, height, memo} = kept(page, memo, opts, width, view_h)
    {fresh_items, fresh_height} = fresh(page, opts, width, view_h)
    assert height == fresh_height
    assert Layout.memo_norm(items) == Layout.memo_norm(fresh_items)
    {items, memo}
  end

  @atoms """
  <div style="display:flex"><div>one item</div><div style="flex:1">two <b>items</b></div></div>
  <p>text <span style="display:inline-block;border:1px solid">inline block</span> after</p>
  <div style="float:left;width:100px">a float</div>
  <table><tr><td>cell one</td><td>cell <i>two</i></td></tr></table>
  <input name=q>
  """

  test "a page laid out again with its memo is laid out from it, and the same" do
    p = page(@atoms)
    {_, _, memo} = kept(p, nil)
    assert map_size(memo.entries) > 0
    same!(p, memo)
  end

  test "an edit is laid out with the memo of the page before it" do
    p = page(@atoms)
    {_, _, memo} = kept(p, nil)
    control = p.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)
    edited = Page.render(p, Forms.put(p.form_state, control.cid, value: "typed"))
    {_, memo} = same!(edited, memo)
    same!(p, memo)
  end

  test "after an edit, the elements it did not change are not walked again" do
    p = page(@atoms)
    {_, _, memo} = kept(p, nil)
    control = p.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)
    edited = Page.render(p, Forms.put(p.form_state, control.cid, value: "typed"))
    {_, kept_memo} = same!(edited, memo)

    reused =
      for {key, {1, _node, _style, ops, _wlog}} <- kept_memo.walk,
          {_, _, _, old_ops, _} <- [memo.walk[key]],
          :erts_debug.same(ops, old_ops),
          do: key

    assert length(reused) >= 4
  end

  # (the layout worker gets each tree as a copy, in a message)
  test "an edited tree that comes as a copy is not walked again either" do
    p = page(@atoms)
    {_, _, memo} = kept(p, nil)
    control = p.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)
    edited = Page.render(p, Forms.put(p.form_state, control.cid, value: "typed"))
    copy = :erlang.binary_to_term(:erlang.term_to_binary(edited.nodes))
    {_, kept_memo} = same!(%{edited | nodes: copy}, memo)

    walked = for {key, {1, _, _, _, _}} <- kept_memo.walk, do: key
    assert length(walked) < map_size(kept_memo.walk) - 4
  end

  test "a picture that arrives between two layouts" do
    html = ~s(<div style="float:left"><img src="a.png"> beside</div><p>text</p>)
    p = page(html)
    {_, _, memo} = kept(p, nil, images: %{})
    {items, _} = same!(p, memo, images: %{"about:a.png" => {:ok, 40, 30}})
    assert Enum.any?(items, &(&1.type == :image))
  end

  test "a positioned box inside an atom laid out twice keeps its paint order" do
    html = """
    <div style="position:relative">before it</div>
    <div style="float:left"><div style="position:relative">in a float</div></div>
    <div style="display:flex"><div><div style="position:relative">in a flex item</div></div></div>
    <table><tr><td><div style="position:relative">in a cell</div></td></tr></table>
    <div style="position:relative">after it</div>
    """

    p = page(html)
    {_, _, memo} = kept(p, nil)
    {_, memo} = same!(p, memo)
    same!(p, memo)
  end

  # (the infobox of the article page: a table with a caption whose column sizes the memo keeps
  # are found again when text elsewhere changes; without spans, whose fragments would hold the
  # table placed)
  test "a text changed in a realistic page" do
    html = File.read!("bench/pages/article.html")
    p = page(html)
    flat = [spans: false]
    {_, _, memo} = kept(p, nil, flat, 1000, 768)

    edited =
      page(
        String.replace(html, "Grid float page table", "Grid float page table edited",
          global: false
        )
      )

    {_, memo} = same!(edited, memo, flat, 1000, 768)

    assert Enum.any?(memo.entries, fn {key, {gen, _, _}} ->
             elem(key, 0) == :tcols and gen == 1
           end)

    same!(p, memo, flat, 1000, 768)
  end

  test "the blocks a text change did not touch are placed from their fragments" do
    html = File.read!("bench/pages/article.html")
    p = page(html)
    {_, _, memo0} = kept(p, nil, [], 1000, 768)

    edited =
      page(String.replace(html, "Grid float page table", "Grid float edited", global: false))

    {_, memo} = same!(edited, memo0, [], 1000, 768)

    placed_again =
      for {key, {1, _ops, [_ | _] = states}} <- memo.frags,
          {0, _, [_ | _] = old} <- [memo0.frags[key]],
          {skey, frag} <- states,
          {_, old_frag} <- [List.keyfind(old, skey, 0)],
          :erts_debug.same(frag, old_frag),
          do: key

    assert length(placed_again) > 10
    same!(p, memo, [], 1000, 768)
  end

  # (a first child's top margin collapses with its parent's: the span is placed again only where
  # it starts its parent the same way)
  test "blocks that start their parent are placed again from their fragments" do
    html = fn text ->
      """
      <div style="margin-top:10px"><p style="margin-top:20px">first</p><p>#{text}</p></div>
      <div><div style="margin:5px"><p style="margin:30px">nested first</p></div></div>
      """
    end

    {_, _, memo} = kept(page(html.("one")), nil)
    {_, memo} = same!(page(html.("two words")), memo)
    same!(page(html.("one")), memo)
  end

  # (an inner block placed again at another y is one entry in the fragment of its outer block;
  # when the outer block is then placed again at another y, its items move by both offsets)
  test "a block placed again inside a block placed again moves by both offsets" do
    html = fn above, before ->
      """
      <p>#{above}</p>
      <div><p>#{before}</p><div><p>inner block text</p><p>more inner text</p></div></div>
      <p>after</p>
      """
    end

    long = Enum.map_join(1..40, " ", &"w#{&1}")
    {_, _, memo} = kept(page(html.("one", "x")), nil)
    {_, memo} = same!(page(html.("one", long)), memo)

    assert Enum.any?(memo.frags, fn {_key, {_gen, _ops, states}} ->
             is_list(states) and
               Enum.any?(states, fn {_skey, frag} ->
                 Enum.any?(frag.items, &match?({:frag, dy, _, _} when dy != 0, &1))
               end)
           end)

    {items, _memo} = same!(page(html.("one " <> long, long)), memo)
    assert Enum.any?(items, &(&1.type == :text and &1.text == "more"))
  end

  # (the inner flex item ends inside the outer one: what comes after it is still in a flex item,
  # whether the inner one is laid out or placed again from its fragment)
  test "a flex item inside a flex item is laid out the same from the memo" do
    html = fn overflow ->
      ~s(<body style="width:700px"><section style="display:flex">adipiscing amet adipiscing ) <>
        ~s(eiusmod ipsum eiusmod ut<section style="overflow:#{overflow}">sed ) <>
        ~s(<div style="position:absolute">eiusmod <p style="display:flex">incididunt </p>) <>
        "labore dolor consectetur lorem tempor amet consectetur incididunt" <>
        ~s(<div style="max-width:90px">lorem<div style="float:left;text-indent:30px">amet ) <>
        "</div></div>adipiscing</div></section></section>"
    end

    {_, _, memo} = kept(page(html.("hidden")), nil, [], 800)
    {_, memo} = same!(page(html.("hidden")), memo, [], 800)
    {_, memo} = same!(page(html.("visible")), memo, [], 800)
    same!(page(html.("hidden")), memo, [], 800)
  end

  # (a measure of content puts the mark of an intrinsic size back as it found it, so that the
  # keys of the memo after it are the same as in a layout whose measures come from the memo)
  test "a float with a positioned box in an inline flex box is laid out the same from the memo" do
    html = fn word ->
      ~s(<body style="width:700px"><b style="display:inline-flex">elit <section>dolor <div>) <>
        ~s(incididunt <b style="float:right">adipiscing <b style="position:absolute">amet </b>) <>
        "sed </b></div>adipiscing elit incididunt labore #{word} tempor</section>dolor " <>
        ~s(<b style="position:relative">labore<fieldset style="width:60%">eiusmod ) <>
        "<fieldset><legend>leg </legend>sed </fieldset></fieldset></b>adipiscing </b>"
    end

    {_, _, memo} = kept(page(html.("lorem")), nil, [], 800)
    {_, memo} = same!(page(html.("lorem lorem extra words here")), memo, [], 800)
    same!(page(html.("lorem")), memo, [], 800)
  end

  test "another window size starts from an empty memo" do
    p = page(~s(<div style="float:left;height:50%">half the window</div><p>text</p>))
    {_, _, memo} = kept(p, nil)
    {_, memo} = same!(p, memo, [], 500, 300)
    assert memo.gen == 0
    same!(p, memo, [], 300, 300)
  end
end
