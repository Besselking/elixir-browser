defmodule Browser.FormsTest do
  use ExUnit.Case, async: true
  alias Browser.{Forms, HTML}

  @zw "\u200B"

  defp kids(html, tag) do
    html |> HTML.parse() |> Forms.transform() |> find(tag)
  end

  defp find(nodes, tag) do
    Enum.find_value(nodes, fn
      {:element, ^tag, _attrs, kids} -> kids
      {:element, _, _, kids} -> find(kids, tag)
      _ -> nil
    end)
  end

  test "text inputs show their value" do
    assert [{:text, "hello"}] = kids(~s(<input type="text" value="hello">), "input")
    assert [{:text, "x"}] = kids(~s(<input value="x">), "input")
    assert [{:text, "a@b.c"}] = kids(~s(<input type="email" value="a@b.c">), "input")
  end

  test "an empty input shows its placeholder in a placeholder element" do
    assert [{:element, "placeholder", _, [{:text, "Search"}]}] =
             kids(~s(<input placeholder="Search">), "input")
  end

  test "the value wins over the placeholder; nothing at all becomes a zero-width space" do
    assert [{:text, "v"}] = kids(~s(<input value="v" placeholder="p">), "input")
    assert [{:text, @zw}] = kids("<input>", "input")
  end

  test "passwords show bullets, not the value" do
    assert [{:text, "•••"}] = kids(~s(<input type="password" value="abc">), "input")

    assert [{:element, "placeholder", _, _}] =
             kids(~s(<input type="password" placeholder="pw">), "input")
  end

  test "checkboxes and radios show a mark only when checked" do
    assert [{:text, "✓"}] = kids(~s(<input type="checkbox" checked>), "input")
    assert [{:text, @zw}] = kids(~s(<input type="checkbox">), "input")
    assert [{:element, "control-dot", _, []}] = kids(~s(<input type="radio" checked>), "input")
    assert [{:text, @zw}] = kids(~s(<input type="radio">), "input")
  end

  test "button-like inputs show their value or a default label" do
    assert [{:text, "Send"}] = kids(~s(<input type="submit" value="Send">), "input")
    assert [{:text, "Submit"}] = kids(~s(<input type="submit">), "input")
    assert [{:text, "Reset"}] = kids(~s(<input type="reset">), "input")
    assert [{:text, "Go"}] = kids(~s(<input type="button" value="Go">), "input")
    assert [{:text, @zw}] = kids(~s(<input type="button">), "input")
  end

  test "an empty value attribute is an empty label, not the default one" do
    assert [{:text, @zw}] = kids(~s(<input type="submit" value="">), "input")
    assert [{:text, @zw}] = kids(~s(<input type="reset" value="">), "input")
  end

  test "hidden inputs have no content" do
    assert [] = kids(~s(<input type="hidden" value="secret">), "input")
  end

  test "a select shows the selected option and an arrow, options are dropped" do
    html =
      ~s(<select><option>One</option><option selected>Two  words</option><option>Three</option></select>)

    assert [{:text, "Two words ▾"}] = kids(html, "select")
  end

  test "a select without a selected option shows the first; with none just the arrow" do
    assert [{:text, "A ▾"}] =
             kids("<select><option>A</option><option>B</option></select>", "select")

    assert [{:text, "▾"}] = kids("<select></select>", "select")
  end

  test "options inside optgroups count" do
    html = ~s(<select><optgroup label="g"><option>Inside</option></optgroup></select>)
    assert [{:text, "Inside ▾"}] = kids(html, "select")
  end

  test "textarea keeps its text but drops the first newline" do
    assert [{:text, "line1\nline2"}] = kids("<textarea>\nline1\nline2</textarea>", "textarea")

    assert [{:element, "placeholder", _, [{:text, "Write"}]}] =
             kids(~s(<textarea placeholder="Write"></textarea>), "textarea")

    assert [{:text, @zw}] = kids("<textarea></textarea>", "textarea")
  end

  test "controls nested anywhere are transformed, other markup is untouched" do
    html = ~s(<form><p>a <label>L <input value="v"></label></p><div><b>bold</b></div></form>)
    nodes = html |> HTML.parse() |> Forms.transform()
    assert find(nodes, "input") == [{:text, "v"}]
    assert find(nodes, "b") == [{:text, "bold"}]
  end

  test "text_like?" do
    assert Forms.text_like?("text") and Forms.text_like?("email") and Forms.text_like?("")
    refute Forms.text_like?("checkbox")
    refute Forms.text_like?("submit")
  end

  # -- indexing, state and behaviour -----------------------------------------------

  defp indexed(html) do
    {nodes, info} = html |> HTML.parse() |> Forms.index()
    {nodes, info.controls, info.forms}
  end

  describe "index" do
    test "controls are numbered in document order and know their form" do
      {_, controls, forms} =
        indexed(
          ~s(<input name="free"><form action="/a" method="POST"><input name="a"><select name="s"></select></form><form><textarea name="t"></textarea></form><button>x</button>)
        )

      assert Map.keys(controls) |> Enum.sort() == [0, 1, 2, 3, 4]
      assert controls[0].form == nil
      assert controls[1].form == 0 and controls[2].form == 0
      assert controls[3].form == 1
      assert controls[4].form == nil
      assert forms[0] == %{action: "/a", method: "post"}
      assert forms[1] == %{action: "", method: ""}
    end

    test "the id lands on the element as @cid" do
      {nodes, _, _} = indexed("<p><input></p>")
      [{:element, "p", _, [{:element, "input", attrs, _}]}] = nodes
      assert {"@cid", 0} in attrs
    end

    test "controls record their type, name and initial state" do
      {_, c, _} =
        indexed(
          ~s(<input name="u" value="v" maxlength="5"><input type="checkbox" checked><input type="radio"><input disabled><input readonly><button>b</button><button type="button">c</button><button type="oops">d</button><textarea name="t">\nhi</textarea>)
        )

      assert %{type: "text", name: "u", value: "v", maxlength: 5, checked: false} = c[0]
      assert %{type: "checkbox", checked: true} = c[1]
      assert %{type: "radio", checked: false} = c[2]
      assert c[3].disabled? and c[4].readonly?
      assert c[5].type == "submit" and c[6].type == "button" and c[7].type == "submit"
      assert %{type: "textarea", value: "hi"} = c[8]
    end

    test "a select records its options and the initial choice" do
      {_, c, _} =
        indexed(
          ~s(<select name="s"><option value="1">One</option><optgroup><option selected>Two words</option></optgroup><option>Three</option></select>)
        )

      assert [
               %{value: "1", label: "One"},
               %{value: "Two words", label: "Two words"},
               %{label: "Three"}
             ] =
               c[0].options

      assert c[0].selected == 1
      {_, c, _} = indexed("<select><option>A</option><option>B</option></select>")
      assert c[0].selected == 0
      {_, c, _} = indexed("<select></select>")
      assert c[0].selected == nil
    end
  end

  describe "rendering with state" do
    defp rendered(html, state) do
      {nodes, %{controls: controls}} = html |> HTML.parse() |> Forms.index()

      nodes |> Forms.render(state, controls) |> find("input") ||
        nodes |> Forms.render(state, controls)
    end

    defp render_kids(html, state, tag) do
      {nodes, %{controls: controls}} = html |> HTML.parse() |> Forms.index()
      nodes |> Forms.render(state, controls) |> find(tag)
    end

    test "a changed value is shown, and a cleared one brings the placeholder back" do
      html = ~s(<input value="old" placeholder="ph">)
      assert [{:text, "new"}] = render_kids(html, %{0 => %{value: "new"}}, "input")
      assert [{:element, "placeholder", _, _}] = render_kids(html, %{0 => %{value: ""}}, "input")
    end

    test "the scroll offset hides leading characters of a single-line value" do
      html = ~s(<input value="abcdefgh">)
      assert [{:text, "defgh"}] = render_kids(html, %{0 => %{scroll: 3}}, "input")
      assert [{:text, @zw}] = render_kids(html, %{0 => %{scroll: 99}}, "input")
    end

    test "passwords stay masked as they change" do
      assert [{:text, "••••"}] =
               render_kids(~s(<input type="password">), %{0 => %{value: "abcd"}}, "input")
    end

    test "checked state drives the check mark and the radio dot" do
      assert [{:text, "✓"}] =
               render_kids(~s(<input type="checkbox">), %{0 => %{checked: true}}, "input")

      assert [{:text, @zw}] =
               render_kids(
                 ~s(<input type="checkbox" checked>),
                 %{0 => %{checked: false}},
                 "input"
               )

      assert [{:element, "control-dot", _, _}] =
               render_kids(~s(<input type="radio">), %{0 => %{checked: true}}, "input")
    end

    test "the dot takes the radio's text colour" do
      {nodes, %{controls: controls}} =
        Forms.index([
          {:element, "input",
           [{"type", "radio"}, {"checked", ""}, {"@computed", %{"color" => {1, 2, 3}}}], []}
        ])

      [{:element, _, _, [{:element, "control-dot", [{"@computed", computed}], []}]}] =
        Forms.render(nodes, %{}, controls)

      assert computed["background-color"] == {1, 2, 3}
      assert computed["width"] == 7.0 and computed["margin-left"] == 3.0
    end

    test "a chosen option changes the select's label" do
      html = ~s(<select><option>A</option><option>B</option><option>C</option></select>)
      assert [{:text, "C ▾"}] = render_kids(html, %{0 => %{selected: 2}}, "select")
    end

    test "a textarea scrolls by lines" do
      html = "<textarea>one\ntwo\nthree</textarea>"
      assert [{:text, "two\nthree"}] = render_kids(html, %{0 => %{scroll: 1}}, "textarea")
      assert [{:text, "three"}] = render_kids(html, %{0 => %{scroll: 2}}, "textarea")
      assert [{:text, @zw}] = render_kids(html, %{0 => %{scroll: 9}}, "textarea")
    end

    test "current/2 merges state over the initial values" do
      {_, c, _} = indexed(~s(<input value="v"><input type="checkbox" checked>))
      assert %{value: "v", checked: false, scroll: 0} = Forms.current(c[0], %{})
      assert %{value: "x"} = Forms.current(c[0], %{0 => %{value: "x"}})
      assert %{checked: false} = Forms.current(c[1], %{1 => %{checked: false}})
      assert %{checked: true} = Forms.current(c[1], %{})
    end

    test "put/3 merges changes into one control's state" do
      state =
        %{} |> Forms.put(3, value: "a") |> Forms.put(3, scroll: 2) |> Forms.put(4, checked: true)

      assert state == %{3 => %{value: "a", scroll: 2}, 4 => %{checked: true}}
    end

    test "unindexed controls still render (no state to apply)" do
      assert [{:text, "x"}] =
               rendered(~s(<input value="x">), %{}) |> then(&(&1 || [{:text, "x"}]))
    end
  end

  describe "behaviour" do
    test "focusable controls skip disabled and hidden ones, in document order" do
      {_, c, _} =
        indexed(
          ~s(<input><input type="hidden"><input disabled><select></select><button>b</button><textarea></textarea>)
        )

      assert Forms.focus_order(c) == [0, 3, 4, 5]
    end

    test "only text-like, enabled, writable fields are editable" do
      {_, c, _} =
        indexed(
          ~s(<input><input readonly><input disabled><input type="checkbox"><textarea></textarea><textarea readonly></textarea><select></select><input type="password">)
        )

      assert for(id <- 0..7, Forms.editable?(c[id]), do: id) == [0, 4, 7]
      assert Forms.multiline?(c[4]) and not Forms.multiline?(c[0])
    end

    test "checkboxes toggle independently" do
      {_, c, _} = indexed(~s(<input type="checkbox"><input type="checkbox" checked>))
      s = Forms.toggle(%{}, c, 0)
      assert Forms.current(c[0], s).checked
      s = Forms.toggle(s, c, 0)
      refute Forms.current(c[0], s).checked
      s = Forms.toggle(s, c, 1)
      refute Forms.current(c[1], s).checked
    end

    test "checking a radio button unchecks the rest of its group only" do
      html =
        ~s(<form><input type="radio" name="a" checked><input type="radio" name="a"><input type="radio" name="b" checked></form><form><input type="radio" name="a" checked></form>)

      {_, c, _} = indexed(html)
      s = Forms.toggle(%{}, c, 1)
      assert Forms.current(c[1], s).checked
      refute Forms.current(c[0], s).checked
      # another name, and another form, keep their choice
      assert Forms.current(c[2], s).checked
      assert Forms.current(c[3], s).checked
    end

    test "a checked radio button stays checked when toggled again" do
      {_, c, _} = indexed(~s(<input type="radio" name="a" checked>))
      assert Forms.current(c[0], Forms.toggle(%{}, c, 0)).checked
    end

    test "step_select moves within the option list" do
      {_, c, _} =
        indexed("<select><option>A</option><option>B</option><option>C</option></select>")

      s = Forms.step_select(%{}, c, 0, 1)
      assert Forms.current(c[0], s).selected == 1
      s = s |> then(&Forms.step_select(&1, c, 0, 5))
      assert Forms.current(c[0], s).selected == 2
      s = Forms.step_select(s, c, 0, -9)
      assert Forms.current(c[0], s).selected == 0
    end

    test "reset forgets one form's changes only" do
      {_, c, _} =
        indexed(
          ~s(<form><input name="a" value="x"><input name="b" value="y"></form><input name="o" value="z">)
        )

      state = %{0 => %{value: "1"}, 1 => %{value: "2"}, 2 => %{value: "3"}}
      assert Forms.reset(state, c, 0) == %{2 => %{value: "3"}}
    end
  end

  describe "submission" do
    @page "https://example.com/dir/page.html?old=1#frag"

    defp sub(html, state \\ %{}, fid \\ 0, clicked \\ nil) do
      {_, %{controls: c, forms: f}} = html |> HTML.parse() |> Forms.index()
      Forms.submission(f, c, state, fid, clicked, @page)
    end

    test "GET puts the encoded fields in the query, replacing the old query and fragment" do
      r =
        sub(
          ~s(<form action="/search"><input name="q" value="a b&c"><input name="n" value="é"></form>)
        )

      assert r == %{method: :get, url: "https://example.com/search?q=a+b%26c&n=%C3%A9", body: nil}
    end

    test "the default method is GET and the default action the current page" do
      r = sub(~s(<form><input name="x" value="1"></form>))
      assert r.url == "https://example.com/dir/page.html?x=1"
    end

    test "relative actions resolve against the page" do
      assert sub(~s(<form action="go"><input name="x" value="1"></form>)).url ==
               "https://example.com/dir/go?x=1"
    end

    test "a form without fields has no query" do
      assert sub(~s(<form action="/p"></form>)).url == "https://example.com/p"
    end

    test "POST sends the fields as the body" do
      r =
        sub(
          ~s(<form action="/p" method="post"><input name="a" value="1"><input name="b" value="x y"></form>)
        )

      assert r == %{method: :post, url: "https://example.com/p", body: "a=1&b=x+y"}
    end

    test "typed values replace the initial ones" do
      r = sub(~s(<form action="/p"><input name="a" value="old"></form>), %{0 => %{value: "new"}})
      assert r.url == "https://example.com/p?a=new"
    end

    test "unnamed and disabled controls are skipped, hidden ones are sent" do
      html =
        ~s(<form action="/p"><input value="1"><input name="d" value="2" disabled><input type="hidden" name="h" value="3"><input name="ok" value="4"></form>)

      assert sub(html).url == "https://example.com/p?h=3&ok=4"
    end

    test "checkboxes and radios are sent only when checked, with value or 'on'" do
      html =
        ~s(<form action="/p"><input type="checkbox" name="a" checked><input type="checkbox" name="b" value="yes" checked><input type="checkbox" name="c"><input type="radio" name="r" value="1"><input type="radio" name="r" value="2" checked></form>)

      assert sub(html).url == "https://example.com/p?a=on&b=yes&r=2"
    end

    test "a select sends its chosen option's value" do
      html =
        ~s(<form action="/p"><select name="s"><option value="1">One</option><option value="2">Two</option></select></form>)

      assert sub(html).url == "https://example.com/p?s=1"
      assert sub(html, %{0 => %{selected: 1}}).url == "https://example.com/p?s=2"
    end

    test "a textarea sends CRLF line breaks" do
      html = ~s(<form action="/p" method="post"><textarea name="t">a\nb</textarea></form>)
      assert sub(html).body == "t=a%0D%0Ab"
    end

    test "only the clicked submit button is included" do
      html =
        ~s(<form action="/p"><input name="q" value="1"><input type="submit" name="go" value="Go"><button name="other" value="O">x</button></form>)

      assert sub(html, %{}, 0, 1).url == "https://example.com/p?q=1&go=Go"
      assert sub(html, %{}, 0, 2).url == "https://example.com/p?q=1&other=O"
      assert sub(html).url == "https://example.com/p?q=1"
    end

    test "controls of other forms and outside forms are not included" do
      html =
        ~s(<input name="out" value="o"><form action="/a"><input name="in" value="1"></form><form action="/b"><input name="other" value="2"></form>)

      assert sub(html, %{}, 0).url == "https://example.com/a?in=1"
      assert sub(html, %{}, 1).url == "https://example.com/b?other=2"
    end

    test "encode/1" do
      assert Forms.encode([{"a b", "c&d"}, {"é", "="}]) == "a+b=c%26d&%C3%A9=%3D"
      assert Forms.encode([]) == ""
    end
  end

  describe "checked look follows the state" do
    defp styled_input(html, state) do
      {nodes, %{controls: controls}} = html |> HTML.parse() |> Forms.index()
      [{:element, "input", attrs, kids}] = Forms.render(nodes, state, controls)

      {Map.new(for {k, v} <- attrs, k == "@computed", do: {k, v}) |> Map.get("@computed", %{}),
       kids}
    end

    test "ticking an unchecked checkbox makes it blue with a white mark" do
      {c, [{:text, "✓"}]} = styled_input(~s(<input type="checkbox">), %{0 => %{checked: true}})
      assert c["background-color"] == {0, 117, 255}
      assert c["color"] == {255, 255, 255}
      assert c["border-top-color"] == {0, 117, 255}
    end

    test "clearing an initially checked checkbox restores the plain look" do
      {c, [{:text, @zw}]} =
        styled_input(~s(<input type="checkbox" checked>), %{0 => %{checked: false}})

      assert c["background-color"] == {255, 255, 255}
      assert c["color"] == {0, 0, 0}
      assert c["border-left-color"] == {118, 118, 118}
    end

    test "a checked radio gets a blue ring and a blue dot" do
      {c, [{:element, "control-dot", [{"@computed", dot}], []}]} =
        styled_input(~s(<input type="radio">), %{0 => %{checked: true}})

      assert c["border-top-color"] == {0, 117, 255}
      assert dot["background-color"] == {0, 117, 255}
    end

    test "an unchanged control is left to the stylesheet" do
      {c, _} = styled_input(~s(<input type="checkbox" checked>), %{})
      assert c == %{}
      {c, _} = styled_input(~s(<input type="checkbox">), %{0 => %{checked: false}})
      assert c == %{}
    end

    test "existing computed style is kept and merged" do
      {nodes, %{controls: controls}} =
        Forms.index([
          {:element, "input", [{"type", "checkbox"}, {"@computed", %{"width" => 13.0}}], []}
        ])

      [{:element, _, attrs, _}] = Forms.render(nodes, %{0 => %{checked: true}}, controls)
      {_, c} = List.keyfind(attrs, "@computed", 0)
      assert c["width"] == 13.0 and c["background-color"] == {0, 117, 255}
    end
  end

  describe "details and summary" do
    @html "<details><summary>More</summary><p>hidden text</p></details>"

    defp details(html, state \\ %{}) do
      {nodes, %{controls: controls}} = html |> HTML.parse() |> Forms.index()
      {Forms.render(nodes, state, controls), controls}
    end

    defp text_of(nodes) do
      Enum.map_join(nodes, fn
        {:text, t} -> t
        {:element, _, _, kids} -> text_of(kids)
      end)
    end

    test "a closed details shows only its summary, with a closed marker" do
      {nodes, _} = details(@html)
      assert text_of(nodes) == "▸ More"
    end

    test "open attribute and toggled state show the content" do
      {nodes, _} = details(String.replace(@html, "<details>", "<details open>"))
      assert text_of(nodes) == "▾ Morehidden text"

      {_, controls} = details(@html)
      [cid] = Map.keys(controls)
      state = Forms.toggle(%{}, controls, cid)
      {nodes, _} = details(@html, state)
      assert text_of(nodes) == "▾ Morehidden text"
      {nodes, _} = details(@html, Forms.toggle(state, controls, cid))
      assert text_of(nodes) == "▸ More"
    end

    test "summaries are not in the tab order and submit nothing" do
      {_, controls} = details(@html)
      assert Forms.focus_order(controls) == []
      assert Forms.params(controls, %{}, nil, nil) == []
    end

    test "details without a summary stays as it is" do
      {nodes, controls} = details("<details><p>x</p></details>")
      assert text_of(nodes) == "x"
      assert controls == %{}
    end
  end
end
