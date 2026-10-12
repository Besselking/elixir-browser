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

  defp fresh(page, opts, width, view_h),
    do: page |> kept(nil, opts, width, view_h) |> Tuple.delete_at(2)

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
  # are found again when text elsewhere changes)
  test "a text changed in a realistic page" do
    html = File.read!("bench/pages/article.html")
    p = page(html)
    {_, _, memo} = kept(p, nil, [], 1000, 768)

    edited =
      page(
        String.replace(html, "Grid float page table", "Grid float page table edited",
          global: false
        )
      )

    {_, memo} = same!(edited, memo, [], 1000, 768)

    assert Enum.any?(memo.entries, fn {key, {gen, _, _}} ->
             elem(key, 0) == :tcols and gen == 1
           end)

    same!(p, memo, [], 1000, 768)
  end

  test "another window size starts from an empty memo" do
    p = page(~s(<div style="float:left;height:50%">half the window</div><p>text</p>))
    {_, _, memo} = kept(p, nil)
    {_, memo} = same!(p, memo, [], 500, 300)
    assert memo.gen == 0
    same!(p, memo, [], 300, 300)
  end
end
