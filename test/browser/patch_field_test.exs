defmodule Browser.PatchFieldTest do
  use ExUnit.Case, async: true
  alias Browser.{Forms, Layout, Page}

  # Typing must give exactly what laying the page out again would whenever
  # `Layout.patch_field/6` agrees to patch, and it must agree in the common cases.

  @typed "elixir browser typing"

  defp measure(text, style), do: String.length(text) * (6 + rem(round(style.size), 3))

  defp layout(page, focus) do
    Layout.layout(page.nodes, 600, &measure/2, 700,
      images: %{},
      svg_defs: page.svg_defs,
      focus: focus
    )
  end

  # Types `@typed` a character at a time into the first text field, patching the previous
  # items whenever the page says that is allowed. Returns how many keystrokes were patched.
  defp type_into(html) do
    type_values(html, for(n <- 0..String.length(@typed), do: String.slice(@typed, 0, n)))
  end

  # Gives the first text field each of `values` in turn (the first one is the field's value at
  # the start), patching as above.
  defp type_values(html, [first | values]) do
    page = Page.build(html, "about:test")
    control = page.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)
    patchable? = MapSet.member?(page.fixed_width, control.cid)
    state = fn text -> Page.render(page, Forms.put(page.form_state, control.cid, value: text)) end
    {items, _} = layout(state.(first), %{cid: control.cid, caret: {0, String.length(first)}})

    {_, _, patched} =
      for value <- values, reduce: {items, first, 0} do
        {items, before, patched} ->
          {old, new} = {state.(before), state.(value)}
          focus = %{cid: control.cid, caret: {0, String.length(value)}}
          {full, _height} = layout(new, focus)

          patch =
            patchable? &&
              Layout.patch_field(
                items,
                control.cid,
                Forms.visible_text(control, Forms.current(control, old.form_state)),
                Forms.visible_text(control, Forms.current(control, new.form_state)),
                focus,
                &measure/2
              )

          case patch do
            {:ok, patched_items} ->
              assert patched_items == full, "#{inspect(value)} differs from a full layout"
              {patched_items, value, patched + 1}

            _ ->
              {full, value, patched}
          end
      end

    patched
  end

  test "typing into a plain input is patched, and equals a full layout" do
    assert type_into(~s(<p>Search: <input name=q> and some text after it</p>)) >= 5
  end

  test "inside centred inline content" do
    html = ~s(<div style="text-align:center"><b>Find</b> <input name=q> <button>Go</button></div>)
    assert type_into(html) >= 5
  end

  test "a password field" do
    assert type_into(~s(<form><input type=password name=p></form>)) >= 5
  end

  test "an input in a flex row is patched, with the same result as a full layout" do
    html =
      ~s(<div style="display:flex"><input name=q style="width:200px"><button>Go</button></div>)

    assert type_into(html) >= 5
  end

  test "right-aligned text in a field is never patched" do
    assert type_into(~s(<input name=q style="text-align:right">)) == 0
  end

  test "an auto-width field is never patched" do
    assert type_into(~s(<input name=q style="width:auto">)) == 0
  end

  test "text too wide for the field falls back to a full layout" do
    # (the first five keystrokes fit, the one from the empty field included; the sixth does not)
    assert type_into(~s(<input name=q style="width:40px">)) < 6
  end

  test "deleting to an empty field and typing again is patched" do
    values = ["ab", "a", "", "x", "", "yz"]
    assert type_values(~s(<p>Search: <input name=q style="width:200px"></p>), values) == 5
  end

  test "a field showing its placeholder is not patched" do
    page = Page.build(~s(<input name=q placeholder="Search" style="width:200px">), "about:test")
    control = page.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)
    assert control.placeholder?
    {items, _} = layout(page, %{cid: control.cid, caret: {0, 0}})

    assert Layout.patch_field(items, control.cid, "", "a", nil, &measure/2) == :error
  end
end
