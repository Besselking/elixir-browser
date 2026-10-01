defmodule Browser.Forms do
  @moduledoc """
  Form controls: identity, state and what they display.

  `index/1` runs once per page, on the parsed tree before styling. It gives every
  `<input>`, `<select>`, `<textarea>` and `<button>` a stable id (the `"@cid"`
  attribute, in document order) and returns what the page can know about the
  controls and forms: `%{controls: %{cid => control}, forms: %{fid => form}}`.

  What users change (typed text, checked boxes, chosen options) lives outside the
  tree, in a state map `%{cid => %{value:, checked:, selected:, scroll:}}` holding
  only the overrides. `render/3` fills each control with the content it should show
  for that state. It runs after the cascade and is cheap, so typing never has to
  re-run it:

    * text-like inputs show their value, else their `placeholder` (a grey
      `<placeholder>` element), else a zero-width space that gives the empty box a
      text line to sit on
    * `password` shows one bullet per character
    * checkboxes show a check mark when checked; radio buttons a round dot
    * buttons show their value (or "Submit"/"Reset")
    * `<select>` shows the selected option followed by an arrow
    * `<textarea>` shows its text
  """

  # keeps an empty control's box one text line tall and gives it a baseline
  @empty "​"

  @controls ~w(input select textarea button)
  @non_text ~w(checkbox radio submit button reset hidden image file color range)

  @doc "Whether an `<input type>` shows editable text."
  def text_like?(type), do: type not in @non_text

  # -- indexing --------------------------------------------------------------------

  @doc """
  Numbers the controls and forms. Returns `{nodes, %{controls: …, forms: …}}`.

  A control is `%{cid, tag, type, name, form, disabled?, readonly?, value, checked,
  selected, options}`: `form` is the id of the enclosing `<form>` (or nil), and
  `value`/`checked`/`selected` are its initial state.
  """
  def index(nodes) do
    {nodes, acc} = index_nodes(nodes, nil, %{n: 0, f: 0, controls: %{}, forms: %{}})
    {nodes, %{controls: acc.controls, forms: acc.forms}}
  end

  defp index_nodes(nodes, form, acc), do: Enum.map_reduce(nodes, acc, &index_node(&1, form, &2))

  defp index_node({:text, _} = t, _form, acc), do: {t, acc}

  defp index_node({:element, "form", attrs, kids}, _form, acc) do
    fid = acc.f

    info = %{
      action: attr(attrs, "action"),
      method: attrs |> attr("method") |> String.downcase()
    }

    acc = %{acc | f: fid + 1, forms: Map.put(acc.forms, fid, info)}
    {kids, acc} = index_nodes(kids, fid, acc)
    {{:element, "form", attrs, kids}, acc}
  end

  defp index_node({:element, tag, attrs, kids}, form, acc) when tag in @controls do
    cid = acc.n
    control = control(cid, tag, attrs, kids, form)
    acc = %{acc | n: cid + 1, controls: Map.put(acc.controls, cid, control)}
    {kids, acc} = index_nodes(kids, form, acc)
    {{:element, tag, attrs ++ [{"@cid", cid}], kids}, acc}
  end

  defp index_node({:element, tag, attrs, kids}, form, acc) do
    {kids, acc} = index_nodes(kids, form, acc)
    {{:element, tag, attrs, kids}, acc}
  end

  defp control(cid, tag, attrs, kids, form) do
    type = control_type(tag, attrs)
    options = if tag == "select", do: options(kids), else: []

    %{
      cid: cid,
      tag: tag,
      type: type,
      name: attr(attrs, "name"),
      form: form,
      disabled?: has?(attrs, "disabled"),
      readonly?: has?(attrs, "readonly"),
      value: initial_value(tag, attrs, kids),
      checked: has?(attrs, "checked"),
      selected: initial_selected(options),
      options: options,
      maxlength: attrs |> attr("maxlength") |> Integer.parse() |> max_length()
    }
  end

  defp max_length({n, ""}) when n >= 0, do: n
  defp max_length(_), do: nil

  defp control_type("input", attrs) do
    case attrs |> attr("type") |> String.downcase() do
      "" -> "text"
      type -> type
    end
  end

  defp control_type("button", attrs) do
    case attrs |> attr("type") |> String.downcase() do
      t when t in ["submit", "reset", "button"] -> t
      _ -> "submit"
    end
  end

  defp control_type(tag, _attrs), do: tag

  defp initial_value("input", attrs, _kids), do: attr(attrs, "value")
  # a newline right after the opening tag is not part of the text
  defp initial_value("textarea", _attrs, kids),
    do: kids |> plain_text() |> String.replace_prefix("\n", "")

  defp initial_value(_tag, attrs, _kids), do: attr(attrs, "value")

  # `[%{value, label, selected?}]`, looking inside optgroups
  defp options(kids) do
    Enum.flat_map(kids, fn
      {:element, "option", attrs, children} ->
        label = children |> plain_text() |> String.split() |> Enum.join(" ")

        [
          %{
            value: if(has?(attrs, "value"), do: attr(attrs, "value"), else: label),
            label: label,
            selected?: has?(attrs, "selected")
          }
        ]

      {:element, "optgroup", _attrs, children} ->
        options(children)

      _ ->
        []
    end)
  end

  defp initial_selected(options) do
    Enum.find_index(options, & &1.selected?) || if(options == [], do: nil, else: 0)
  end

  # -- state -----------------------------------------------------------------------

  @doc "The control's current `%{value, checked, selected, scroll}` given the state map."
  def current(control, state) do
    st = Map.get(state, control.cid, %{})

    %{
      value: Map.get(st, :value, control.value),
      checked: Map.get(st, :checked, control.checked),
      selected: Map.get(st, :selected, control.selected),
      scroll: Map.get(st, :scroll, 0)
    }
  end

  @doc "Merges `changes` into one control's state."
  def put(state, cid, changes),
    do: Map.update(state, cid, Map.new(changes), &Map.merge(&1, Map.new(changes)))

  # -- rendering -------------------------------------------------------------------

  @doc "Fills every indexed control in `nodes` with its display content."
  def render(nodes, state, controls), do: Enum.map(nodes, &render_node(&1, state, controls))

  defp render_node({:text, _} = t, _state, _controls), do: t

  defp render_node({:element, tag, attrs, kids}, state, controls)
       when tag in ["input", "select", "textarea"] do
    with {_, cid} <- List.keyfind(attrs, "@cid", 0),
         %{} = control <- Map.get(controls, cid) do
      cur = current(control, state)
      attrs = restyle_checked(attrs, control, cur)
      {:element, tag, attrs, content(control, attrs, cur)}
    else
      _ -> {:element, tag, attrs, kids}
    end
  end

  defp render_node({:element, tag, attrs, kids}, state, controls),
    do: {:element, tag, attrs, render(kids, state, controls)}

  # The default stylesheet draws `[checked]` boxes blue, but the cascade only sees the
  # attribute. Once the user's choice differs from it, apply the matching look here.
  @grey {118, 118, 118}
  @blue {0, 117, 255}

  defp restyle_checked(attrs, %{type: type, checked: initial}, %{checked: now})
       when type in ["checkbox", "radio"] and initial != now do
    {bg, fg, border} =
      case {type, now} do
        {"checkbox", true} -> {@blue, {255, 255, 255}, @blue}
        {"radio", true} -> {{255, 255, 255}, @blue, @blue}
        _ -> {{255, 255, 255}, {0, 0, 0}, @grey}
      end

    changes = %{
      "background-color" => bg,
      "color" => fg,
      "border-top-color" => border,
      "border-right-color" => border,
      "border-bottom-color" => border,
      "border-left-color" => border
    }

    case List.keyfind(attrs, "@computed", 0) do
      {_, computed} ->
        List.keyreplace(attrs, "@computed", 0, {"@computed", Map.merge(computed, changes)})

      nil ->
        attrs ++ [{"@computed", changes}]
    end
  end

  defp restyle_checked(attrs, _control, _cur), do: attrs

  defp content(%{tag: "input", type: type}, attrs, cur) do
    placeholder = attr(attrs, "placeholder")

    case type do
      "hidden" -> []
      "checkbox" -> [text(if cur.checked, do: "✓", else: @empty)]
      "radio" -> if cur.checked, do: [dot(attrs)], else: [text(@empty)]
      t when t in ["submit", "button", "reset"] -> [text(button_label(t, cur.value))]
      "image" -> [text(first_present([attr(attrs, "alt"), cur.value], "Submit"))]
      "file" -> [text("Choose file")]
      "password" -> shown(String.duplicate("•", String.length(cur.value)), cur, placeholder)
      _ -> shown(cur.value, cur, placeholder)
    end
  end

  # a textarea scrolls by whole lines
  defp content(%{tag: "textarea"}, attrs, cur) do
    case {cur.value, attr(attrs, "placeholder")} do
      {"", placeholder} ->
        shown("", cur, placeholder)

      {value, _placeholder} ->
        case value |> String.split("\n") |> Enum.drop(cur.scroll) |> Enum.join("\n") do
          "" -> [text(@empty)]
          visible -> [text(visible)]
        end
    end
  end

  defp content(%{tag: "select", options: options}, _attrs, cur) do
    label =
      case cur.selected && Enum.at(options, cur.selected) do
        %{label: label} -> label
        _ -> ""
      end

    [text(String.trim(label <> " ▾"))]
  end

  defp button_label("submit", ""), do: "Submit"
  defp button_label("reset", ""), do: "Reset"
  defp button_label(_type, ""), do: @empty
  defp button_label(_type, value), do: value

  defp first_present(values, default), do: Enum.find(values, default, &(&1 != ""))

  # the text, scrolled by `scroll` characters; an empty control shows its placeholder instead
  defp shown("", _cur, ""), do: [text(@empty)]

  defp shown("", _cur, placeholder),
    do: [
      {:element, "placeholder", [{"@computed", %{"color" => {117, 117, 117}}}],
       [text(placeholder)]}
    ]

  defp shown(display, %{scroll: scroll}, _placeholder) do
    case String.slice(display, scroll..-1//1) do
      "" -> [text(@empty)]
      visible -> [text(visible)]
    end
  end

  # the radio button's dot: a small round box, centred by its margins
  defp dot(attrs) do
    color =
      case List.keyfind(attrs, "@computed", 0) do
        {_, %{"color" => {_, _, _} = c}} -> c
        _ -> {0, 0, 0}
      end

    round = {{:pct, 0.5}, {:pct, 0.5}}

    computed = %{
      "display" => "inline-block",
      "width" => 7.0,
      "height" => 7.0,
      "margin-top" => 3.0,
      "margin-right" => 3.0,
      "margin-bottom" => 3.0,
      "margin-left" => 3.0,
      "background-color" => color,
      "border-top-left-radius" => round,
      "border-top-right-radius" => round,
      "border-bottom-right-radius" => round,
      "border-bottom-left-radius" => round
    }

    {:element, "control-dot", [{"@computed", computed}], []}
  end

  # -- behaviour -------------------------------------------------------------------

  @doc "Whether the control can take keyboard focus."
  def focusable?(%{disabled?: true}), do: false
  def focusable?(%{type: "hidden"}), do: false
  def focusable?(_control), do: true

  @doc "Control ids in tab order (document order)."
  def focus_order(controls) do
    controls |> Map.values() |> Enum.filter(&focusable?/1) |> Enum.map(& &1.cid) |> Enum.sort()
  end

  @doc "Whether typing edits this control's text."
  def editable?(%{disabled?: true}), do: false
  def editable?(%{readonly?: true}), do: false
  def editable?(%{tag: "textarea"}), do: true
  def editable?(%{tag: "input", type: type}), do: text_like?(type)
  def editable?(_control), do: false

  @doc "Whether the control is a multi-line text field."
  def multiline?(%{tag: "textarea"}), do: true
  def multiline?(_control), do: false

  @doc """
  Checks or unchecks a checkbox or radio button. Checking a radio button unchecks the
  others in its group (same form and name); a radio button can't be unchecked directly.
  """
  def set_checked(state, controls, cid, checked?) do
    control = Map.fetch!(controls, cid)

    case control.type do
      "radio" when checked? ->
        group =
          for {id, %{type: "radio"} = other} <- controls,
              id != cid,
              other.name == control.name,
              other.form == control.form,
              do: id

        state = Enum.reduce(group, state, &put(&2, &1, checked: false))
        put(state, cid, checked: true)

      "radio" ->
        state

      "checkbox" ->
        put(state, cid, checked: checked?)

      _ ->
        state
    end
  end

  @doc "Toggles a checkbox, or checks a radio button."
  def toggle(state, controls, cid) do
    control = Map.fetch!(controls, cid)
    set_checked(state, controls, cid, not current(control, state).checked)
  end

  @doc "Moves a select's choice by `delta` options, staying within the list."
  def step_select(state, controls, cid, delta) do
    control = Map.fetch!(controls, cid)

    case control.options do
      [] ->
        state

      options ->
        now = current(control, state).selected || 0
        put(state, cid, selected: now |> Kernel.+(delta) |> max(0) |> min(length(options) - 1))
    end
  end

  @doc "Forgets everything the user changed in one form, so its controls show their initial state."
  def reset(state, controls, form) do
    ids = for {cid, %{form: ^form}} <- controls, do: cid
    Map.drop(state, ids)
  end

  # -- submission ------------------------------------------------------------------

  @doc """
  Builds the request for submitting form `fid`: `%{method: :get | :post, url:, body:}`.

  `clicked` is the id of the submit button that was used (its name/value is included),
  or nil when submitting with the Enter key. Following the HTML rules, controls without
  a name or that are disabled are skipped, unchecked boxes and radio buttons are skipped,
  and a select contributes its chosen option's value.
  """
  def submission(forms, controls, state, fid, clicked, page_url) do
    form = Map.get(forms, fid, %{action: "", method: ""})
    params = params(controls, state, fid, clicked)
    query = encode(params)

    action =
      if form.action == "", do: page_url, else: Browser.Fetch.resolve(page_url, form.action)

    uri = URI.parse(action)

    case form.method do
      "post" ->
        %{method: :post, url: URI.to_string(%{uri | fragment: nil}), body: query}

      _ ->
        url = URI.to_string(%{uri | query: if(query == "", do: nil, else: query), fragment: nil})
        %{method: :get, url: url, body: nil}
    end
  end

  @doc "The `[{name, value}]` pairs a form submits, in document order."
  def params(controls, state, fid, clicked) do
    controls
    |> Map.values()
    |> Enum.filter(&(&1.form == fid and &1.name != "" and not &1.disabled?))
    |> Enum.sort_by(& &1.cid)
    |> Enum.flat_map(&pair(&1, current(&1, state), clicked))
  end

  defp pair(%{type: type} = c, cur, clicked) do
    cond do
      c.tag == "select" ->
        case cur.selected && Enum.at(c.options, cur.selected) do
          %{value: value} -> [{c.name, value}]
          _ -> []
        end

      c.tag == "textarea" ->
        [{c.name, String.replace(cur.value, "\n", "\r\n")}]

      type in ["checkbox", "radio"] ->
        if cur.checked, do: [{c.name, if(cur.value == "", do: "on", else: cur.value)}], else: []

      type in ["submit", "image"] ->
        if c.cid == clicked, do: [{c.name, cur.value}], else: []

      type in ["reset", "button", "file"] ->
        []

      true ->
        [{c.name, cur.value}]
    end
  end

  @doc "`application/x-www-form-urlencoded` for a list of pairs."
  def encode(params) do
    Enum.map_join(params, "&", fn {k, v} ->
      URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v)
    end)
  end

  @doc """
  Convenience for tests and one-off use: index and render with the initial state.
  """
  def transform(nodes) do
    {nodes, %{controls: controls}} = index(nodes)
    render(nodes, %{}, controls)
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
