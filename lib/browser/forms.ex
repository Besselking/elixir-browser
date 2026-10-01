defmodule Browser.Forms do
  @moduledoc """
  Gives form controls something to draw.

  Controls are static here (no focus, typing or clicking), but they should look
  like what they hold. `transform/1` replaces the children of `<input>`,
  `<select>` and `<textarea>` with the text the control would display, so the
  usual inline-block layout, backgrounds and borders (from the default
  stylesheet in `Browser.Style`) do the rest:

    * text-like inputs show their `value`, else their `placeholder` (as a
      `<placeholder>` element, styled grey), else a zero-width space that gives
      the empty box a text line to sit on
    * `password` shows one bullet per character
    * checkboxes and radio buttons show a check mark or dot when `checked`
    * buttons show their `value` (or "Submit"/"Reset")
    * `<select>` shows the selected option followed by an arrow, and its
      `<option>`s are dropped
    * `<textarea>` keeps its text
  """

  # keeps an empty control's box one text line tall and gives it a baseline
  @empty "​"

  @non_text ~w(checkbox radio submit button reset hidden image file color range)

  def transform(nodes), do: Enum.map(nodes, &visit/1)

  @doc "Whether an `<input type>` shows editable text."
  def text_like?(type), do: type not in @non_text

  defp visit({:text, _} = t), do: t
  defp visit({:element, "input", attrs, _}), do: {:element, "input", attrs, input_kids(attrs)}

  defp visit({:element, "select", attrs, kids}),
    do: {:element, "select", attrs, select_kids(kids)}

  defp visit({:element, "textarea", attrs, kids}),
    do: {:element, "textarea", attrs, textarea_kids(attrs, kids)}

  defp visit({:element, tag, attrs, kids}), do: {:element, tag, attrs, transform(kids)}

  # -- input -----------------------------------------------------------------------

  defp input_kids(attrs) do
    type = attrs |> attr("type") |> String.downcase()
    value = attr(attrs, "value")

    cond do
      type == "hidden" -> []
      type == "checkbox" -> [text(if has?(attrs, "checked"), do: "✓", else: @empty)]
      type == "radio" -> [text(if has?(attrs, "checked"), do: "●", else: @empty)]
      type in ["submit", "button", "reset"] -> [text(button_label(type, value))]
      type == "image" -> [text(first_present([attr(attrs, "alt"), value], "Submit"))]
      type == "file" -> [text("Choose file")]
      type == "password" and value != "" -> [text(String.duplicate("•", String.length(value)))]
      true -> shown_text(value, attr(attrs, "placeholder"))
    end
  end

  defp button_label("submit", ""), do: "Submit"
  defp button_label("reset", ""), do: "Reset"
  defp button_label(_type, ""), do: @empty
  defp button_label(_type, value), do: value

  defp first_present(values, default), do: Enum.find(values, default, &(&1 != ""))

  # the value if there is one, else the placeholder in its own element
  defp shown_text("", ""), do: [text(@empty)]
  defp shown_text("", placeholder), do: [{:element, "placeholder", [], [text(placeholder)]}]
  defp shown_text(value, _placeholder), do: [text(value)]

  # -- select ----------------------------------------------------------------------

  defp select_kids(kids) do
    options = options(kids)

    chosen =
      Enum.find(options, &has?(elem(&1, 0), "selected")) || List.first(options)

    label =
      case chosen do
        {_attrs, text} -> text |> String.split() |> Enum.join(" ")
        nil -> ""
      end

    [text(String.trim(label <> " ▾"))]
  end

  defp options(kids) do
    Enum.flat_map(kids, fn
      {:element, "option", attrs, children} -> [{attrs, plain_text(children)}]
      {:element, "optgroup", _attrs, children} -> options(children)
      _ -> []
    end)
  end

  # -- textarea --------------------------------------------------------------------

  defp textarea_kids(attrs, kids) do
    # a newline right after the opening tag is not part of the text
    content = kids |> plain_text() |> String.replace_prefix("\n", "")

    if content == "",
      do: shown_text("", attr(attrs, "placeholder")),
      else: [text(content)]
  end

  # -- helpers ---------------------------------------------------------------------

  defp plain_text(nodes) do
    Enum.map_join(nodes, fn
      {:text, t} -> t
      {:element, _, _, kids} -> plain_text(kids)
    end)
  end

  defp text(t), do: {:text, t}
  defp attr(attrs, name), do: List.keyfind(attrs, name, 0, {nil, ""}) |> elem(1)
  defp has?(attrs, name), do: List.keymember?(attrs, name, 0)
end
