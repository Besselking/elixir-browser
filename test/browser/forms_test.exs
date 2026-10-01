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
    assert [{:element, "placeholder", [], [{:text, "Search"}]}] =
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
    assert [{:text, "●"}] = kids(~s(<input type="radio" checked>), "input")
    assert [{:text, @zw}] = kids(~s(<input type="radio">), "input")
  end

  test "button-like inputs show their value or a default label" do
    assert [{:text, "Send"}] = kids(~s(<input type="submit" value="Send">), "input")
    assert [{:text, "Submit"}] = kids(~s(<input type="submit">), "input")
    assert [{:text, "Reset"}] = kids(~s(<input type="reset">), "input")
    assert [{:text, "Go"}] = kids(~s(<input type="button" value="Go">), "input")
    assert [{:text, @zw}] = kids(~s(<input type="button">), "input")
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
end
