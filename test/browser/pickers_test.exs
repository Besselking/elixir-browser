defmodule Browser.PickersTest do
  use ExUnit.Case, async: true
  alias Browser.{Forms, Layout, Page, Pickers}

  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp items(html) do
    page = Page.build("<style>body{margin:0}</style>" <> html, "about:home")
    {items, _} = Layout.layout(page.nodes, 400, &measure/2)
    items
  end

  defp control(html) do
    page = Page.build(html, "about:home")
    page.forms.controls |> Map.values() |> hd()
  end

  describe "range" do
    test "the bounds, and the value kept between them and on the step" do
      assert Forms.range_bounds([]) == {0.0, 100.0, 1.0}

      assert Forms.range_bounds([{"min", "10"}, {"max", "20"}, {"step", "5"}]) ==
               {10.0, 20.0, 5.0}

      b = {0.0, 10.0, 2.0}
      assert Forms.range_value("7", b) == "8"
      assert Forms.range_value("99", b) == "10"
      assert Forms.range_value("-4", b) == "0"
      assert Forms.range_value("", b) == "6"
      assert Forms.range_value("x", {0.0, 100.0, 1.0}) == "50"
    end

    test "a fraction of the track is a value, and back" do
      b = {0.0, 200.0, 1.0}
      assert Forms.range_from_frac(0.25, b) == "50"
      assert Forms.range_frac("50", b) == 0.25
      assert Forms.range_step("50", 3, b) == "53"
      assert Forms.range_step("199", 5, b) == "200"
      assert Forms.range_from_frac(0.17, {0.0, 1.0, 0.1}) == "0.2"
    end

    test "the control holds its value and bounds, and the layout draws the slider" do
      c = control(~s(<input type=range min=0 max=10 value=3 name=v>))
      assert c.value == "3"
      assert c.range == {0.0, 10.0, 1.0}
      refute Forms.editable?(c)

      svg = Enum.filter(items(~s(<input type=range value=30>)), &(&1.type == :svg))
      assert [%{w: 129, h: 16, ops: [_ | _]}] = svg
    end

    test "the width of the control is the width of the slider" do
      assert [%{w: 300}] =
               items(~s(<input type=range style="width:300px">))
               |> Enum.filter(&(&1.type == :svg))
    end
  end

  describe "colour" do
    test "a colour value is #rrggbb in lower case, black when it is not valid" do
      assert Pickers.color_value("#FF6600") == "#ff6600"
      assert Pickers.color_value("red") == "#000000"
      assert Pickers.color_value(nil) == "#000000"
      assert Pickers.rgb("#ff6600") == {255, 102, 0}
      assert Pickers.color_text({255, 102, 0}) == "#ff6600"
    end

    test "the control holds the colour and the field shows it" do
      assert control(~s(<input type=color value="#00FF00">)).value == "#00ff00"
      assert control(~s(<input type=color>)).value == "#000000"
      assert Forms.picker?(control(~s(<input type=color>)))
      refute Forms.picker?(control(~s(<input type=text>)))
    end
  end

  describe "dates" do
    test "the date of a field, and the text of a chosen date" do
      d = ~D[2026-10-21]
      assert Pickers.date_of("date", "2026-10-21") == d
      assert Pickers.date_of("datetime-local", "2026-10-21T09:30") == d
      assert Pickers.date_of("month", "2026-10") == ~D[2026-10-01]
      assert Pickers.date_of("week", "2026-W43") == ~D[2026-10-19]
      assert %Date{} = Pickers.date_of("date", "junk")

      assert Pickers.date_text("date", d, "") == "2026-10-21"
      assert Pickers.date_text("month", d, "") == "2026-10"
      assert Pickers.date_text("week", d, "") == "2026-W43"
      assert Pickers.date_text("datetime-local", d, "2026-01-01T09:30") == "2026-10-21T09:30"
      assert Pickers.date_text("datetime-local", d, "") == "2026-10-21T00:00"

      assert Pickers.date_text("datetime-local", d, "2026-01-01T09:30", {7, 5}) ==
               "2026-10-21T07:05"

      assert Pickers.time_of("2026-01-01T09:30") == {9, 30}
      assert Pickers.time_of("") == {0, 0}
    end

    test "a date field is a text field with a calendar button" do
      c = control(~s(<input type=date value="2026-10-21">))
      assert Forms.editable?(c) and Forms.picker?(c)
      icons = items(~s(<input type=date>)) |> Enum.filter(&(&1.type == :svg))
      assert [%{w: 16, h: 16}] = icons
    end
  end

  describe "time" do
    test "the clock of a time field" do
      assert Pickers.clock_of("14:05") == {14, 5}
      assert Pickers.clock_of("") == {0, 0}
      assert Pickers.clock_of("99:99") == {23, 59}
      assert Pickers.clock_text({7, 5}) == "07:05"
    end
  end
end
