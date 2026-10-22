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
    * buttons show their value (or "Submit"/"Reset" when it is missing)
    * `<select>` shows the selected option followed by an arrow
    * `<textarea>` shows its text

  A `<details>` has one control too: its first `<summary>`, which counts as "checked"
  while the details is open (the `open` attribute is the initial state). The `<details>`
  carries the summary's id as `"@summary"`; closed, `render/3` leaves only its summary, and
  the summary shows a triangle unless its `list-style` is `none`.
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

  A control is `%{cid, tag, type, name, form, disabled?, inert?, readonly?, value, checked,
  selected, options}`: `form` is the id of the enclosing `<form>` (or nil), and
  `value`/`checked`/`selected` are its initial state.
  """
  def index(nodes) do
    # while a modal dialog is open, what is outside the last one is inert, like what has `inert`
    acc = %{n: 0, f: 0, controls: %{}, forms: %{}, modals: Browser.Modal.count(nodes), seen: 0}
    acc = Map.put(acc, :inert, acc.modals > 0)
    {nodes, acc} = index_nodes(nodes, nil, acc)
    {nodes, %{controls: acc.controls, forms: acc.forms}}
  end

  defp index_nodes(nodes, form, acc), do: Enum.map_reduce(nodes, acc, &index_node(&1, form, &2))

  defp index_node({:text, _} = t, _form, acc), do: {t, acc}

  defp index_node({:element, tag, attrs, _} = el, form, acc) do
    outer = acc.inert
    modal? = Browser.Modal.modal?(tag, attrs)
    acc = if modal?, do: %{acc | seen: acc.seen + 1}, else: acc
    # the last modal dialog and what is in it take part; `inert` takes a whole subtree out
    inert = if modal? and acc.seen == acc.modals, do: false, else: outer
    inert = inert or has?(attrs, "inert")
    {node, acc} = index_el(el, form, %{acc | inert: inert})
    {node, %{acc | inert: outer}}
  end

  defp index_el({:element, "form", attrs, kids}, _form, acc) do
    fid = acc.f

    info = %{
      action: attr(attrs, "action"),
      method: attrs |> attr("method") |> String.downcase()
    }

    acc = %{acc | f: fid + 1, forms: Map.put(acc.forms, fid, info)}
    {kids, acc} = index_nodes(kids, fid, acc)
    {{:element, "form", attrs, kids}, acc}
  end

  defp index_el({:element, "details", attrs, kids}, form, acc) do
    case Enum.find_index(kids, &match?({:element, "summary", _, _}, &1)) do
      nil ->
        {kids, acc} = index_nodes(kids, form, acc)
        {{:element, "details", attrs, kids}, acc}

      at ->
        {:element, "summary", sattrs, skids} = Enum.at(kids, at)
        cid = acc.n

        control = %{
          control(cid, "summary", sattrs, skids, form, acc.inert)
          | checked: has?(attrs, "open")
        }

        acc = %{acc | n: cid + 1, controls: Map.put(acc.controls, cid, control)}
        {skids, acc} = index_nodes(skids, form, acc)
        summary = {:element, "summary", sattrs ++ [{"@cid", cid}], skids}
        {before, [_ | rest]} = Enum.split(kids, at)
        {before, acc} = index_nodes(before, form, acc)
        {rest, acc} = index_nodes(rest, form, acc)
        {{:element, "details", attrs ++ [{"@summary", cid}], before ++ [summary | rest]}, acc}
    end
  end

  defp index_el({:element, tag, attrs, kids}, form, acc) when tag in @controls do
    cid = acc.n
    control = control(cid, tag, attrs, kids, form, acc.inert)
    acc = %{acc | n: cid + 1, controls: Map.put(acc.controls, cid, control)}
    {kids, acc} = index_nodes(kids, form, acc)
    {{:element, tag, attrs ++ [{"@cid", cid}], kids}, acc}
  end

  defp index_el({:element, tag, attrs, kids}, form, acc) do
    {kids, acc} = index_nodes(kids, form, acc)
    {{:element, tag, attrs, kids}, acc}
  end

  defp control(cid, tag, attrs, kids, form, inert?) do
    type = control_type(tag, attrs)
    options = if tag == "select", do: options(kids), else: []

    %{
      cid: cid,
      tag: tag,
      type: type,
      name: attr(attrs, "name"),
      form: form,
      disabled?: has?(attrs, "disabled"),
      inert?: inert?,
      readonly?: has?(attrs, "readonly"),
      value: initial_value(tag, attrs, kids) |> range_initial(type, attrs) |> color_initial(type),
      range: if(type == "range" and tag == "input", do: range_bounds(attrs)),
      checked: has?(attrs, "checked"),
      selected: initial_selected(options),
      options: options,
      maxlength: attrs |> attr("maxlength") |> Integer.parse() |> max_length(),
      placeholder?: attr(attrs, "placeholder") != ""
    }
  end

  # -- range sliders -------------------------------------------------------------------

  @doc """
  `{min, max, step}` of an `<input type=range>` (0, 100 and 1 when missing or not numbers).
  `step="any"` is a very small step.
  """
  def range_bounds(attrs) do
    min = number(attr(attrs, "min")) || 0.0
    max = number(attr(attrs, "max")) || 100.0

    step =
      case {attr(attrs, "step"), number(attr(attrs, "step"))} do
        {"any", _} -> 1.0e-6
        {_, n} when is_number(n) and n > 0 -> n
        _ -> 1.0
      end

    {min, max(max, min), step}
  end

  defp number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp range_initial(value, "range", attrs), do: range_value(value, range_bounds(attrs))
  defp range_initial(value, _type, _attrs), do: value

  # a colour input holds `#rrggbb` (black when it has no valid colour)
  defp color_initial(value, "color"), do: Browser.Pickers.color_value(value)
  defp color_initial(value, _type), do: value

  @doc """
  The value of a range with the number in `text` (the middle when it is not one), kept between
  its bounds and on its step, as the text a control holds.
  """
  def range_value(text, {min, max, step}) do
    v = number(text) || min + (max - min) / 2
    v = min(max(v, min), max)
    snapped = min + Float.round((v - min) / step) * step
    snapped = min(snapped, max) |> Float.round(10)
    format_number(snapped)
  end

  @doc "The value of a range with its thumb at `frac` (0.0 to 1.0) of the track."
  def range_from_frac(frac, {min, max, _step} = bounds),
    do: range_value(Float.to_string(min + (max - min) * min(max(frac, 0.0), 1.0)), bounds)

  @doc "Where the thumb of a range with `value` is: 0.0 to 1.0 of the track."
  def range_frac(value, {min, max, _step}) do
    if max > min, do: min(max(((number(value) || min) - min) / (max - min), 0.0), 1.0), else: 0.0
  end

  @doc "The value after `delta` steps (negative: back) from `value`."
  def range_step(value, delta, {min, max, step} = bounds),
    do:
      range_value(
        Float.to_string(min(max((number(value) || min) + delta * step, min), max)),
        bounds
      )

  defp format_number(v) do
    if v == Float.round(v, 0) and abs(v) < 1.0e15,
      do: v |> trunc() |> Integer.to_string(),
      else: Float.to_string(v)
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

  @doc """
  Fills every indexed control in `nodes` with its display content.

  A node whose rendering did not change is given back as the very same term, so that what comes
  after (the layout) can tell the subtrees an edit left alone: the node at the same place in
  `prevs` (the tree the last render gave) when its rendering is that, else the node of `nodes`
  when its rendering is the node itself.
  """
  #
  # `hot` (from `hot/1`), when given, names the elements that hold a control: the others are
  # given back without a look inside.
  def render(nodes, state, controls, prevs \\ nil, hot \\ nil),
    do: render_in(nodes, state, {controls, hot}, prevs)

  defp render_in(nodes, state, ctx, prevs) do
    prevs = paired(nodes, prevs)
    the_list(render_list(nodes, state, ctx, prevs), nodes, prevs)
  end

  # the last render's nodes, when they can be paired with `nodes` by their place
  defp paired(nodes, prevs) do
    if is_list(prevs) and length(prevs) == length(nodes), do: prevs
  end

  # A rendering is `:prev` (the same as the node of the last render), `:same` (the same as the
  # node given) or `{:new, node}`. (The answer is an atom, not the old term, as the compiler may
  # give back the new term for the old one when the two compare equal.)
  defp render_list(nodes, state, controls, nil) do
    {results, same?} = render_each(nodes, state, controls, [], true)
    if same?, do: :same, else: {:new, results}
  end

  defp render_list(nodes, state, controls, prevs) do
    {results, prev?, same?} = render_pairs(nodes, prevs, state, controls, [], true, true)

    cond do
      prev? -> :prev
      same? -> :same
      true -> {:new, results}
    end
  end

  defp render_each([], _state, _controls, acc, same?), do: {:lists.reverse(acc), same?}

  defp render_each([node | nodes], state, controls, acc, same?) do
    r = render_node(node, state, controls, nil)
    render_each(nodes, state, controls, [r | acc], same? and r == :same)
  end

  defp render_pairs([], _prevs, _state, _controls, acc, prev?, same?),
    do: {:lists.reverse(acc), prev?, same?}

  defp render_pairs([node | nodes], [prev | prevs], state, controls, acc, prev?, same?) do
    r = render_node(node, state, controls, prev)
    acc = [r | acc]
    render_pairs(nodes, prevs, state, controls, acc, prev? and r == :prev, same? and r == :same)
  end

  defp the_list(:same, nodes, _prevs), do: nodes
  defp the_list(:prev, _nodes, prevs), do: prevs

  defp the_list({:new, results}, nodes, nil),
    do: Enum.zip_with(results, nodes, &the_node(&1, &2, nil))

  defp the_list({:new, results}, nodes, prevs), do: the_nodes(results, nodes, prevs, [])

  defp the_nodes([r | results], [node | nodes], [prev | prevs], acc),
    do: the_nodes(results, nodes, prevs, [the_node(r, node, prev) | acc])

  defp the_nodes([], [], [], acc), do: :lists.reverse(acc)

  defp the_node(:same, node, _prev), do: node
  defp the_node(:prev, _node, prev), do: prev
  defp the_node({:new, node}, _node, _prev), do: node

  # (`===` takes a term that is the same in memory as equal without looking into it, so comparing
  # a rendering with the node it came from costs only the path to what changed)
  defp classify(new, node, prev) do
    cond do
      new === prev -> :prev
      new === node -> :same
      true -> {:new, new}
    end
  end

  defp render_node({:text, _} = t, _state, _controls, prev),
    do: if(t === prev, do: :prev, else: :same)

  defp render_node({:element, tag, attrs, _} = node, state, controls, prev)
       when tag in ["input", "select", "textarea"] do
    with {_, cid} <- List.keyfind(attrs, "@cid", 0),
         %{} = control <- Map.get(elem(controls, 0), cid) do
      cur = current(control, state)
      attrs = restyle_checked(attrs, control, cur)
      classify({:element, tag, attrs, content(control, attrs, cur)}, node, prev)
    else
      _ -> :same
    end
  end

  # the bar of <progress> and <meter>: a canvas as big as the element that the layout draws
  defp render_node({:element, tag, attrs, _} = node, _state, _controls, prev)
       when tag in ["progress", "meter"] do
    computed = %{"display" => "block", "width" => {:pct, 1.0}, "height" => {:pct, 1.0}}

    bar =
      {:element, "canvas", [{"@computed", computed}, {"@bar", meter_bar(tag, attrs)}], []}

    classify({:element, tag, attrs, [bar]}, node, prev)
  end

  defp render_node({:element, "details", attrs, kids} = node, state, controls, prev) do
    kids =
      with {_, cid} <- List.keyfind(attrs, "@summary", 0),
           %{} = control <- Map.get(elem(controls, 0), cid),
           %{checked: false} <- current(control, state) do
        # closed: only the summary stays
        Enum.filter(kids, &summary?(&1, cid))
      else
        _ -> kids
      end

    classify(
      {:element, "details", attrs, render_in(kids, state, controls, prev_kids(prev))},
      node,
      prev
    )
  end

  defp render_node({:element, "summary", attrs, kids} = node, state, controls, prev) do
    mark =
      with {_, cid} <- List.keyfind(attrs, "@cid", 0),
           %{} = control <- Map.get(elem(controls, 0), cid),
           mark when mark not in [nil, ""] <-
             summary_marker(attrs, current(control, state).checked) do
        mark
      else
        _ -> nil
      end

    kids =
      if mark do
        # (the marker the last render put first is not one of the children)
        pkids = with [{:text, _} | pkids] <- prev_kids(prev), do: pkids, else: (_ -> nil)
        [text(mark) | render_in(kids, state, controls, pkids)]
      else
        render_in(kids, state, controls, prev_kids(prev))
      end

    classify({:element, "summary", attrs, kids}, node, prev)
  end

  defp render_node({:element, tag, attrs, kids} = node, state, controls, prev) do
    if cold?(attrs, controls),
      do: if(node === prev, do: :prev, else: :same),
      else: render_element(tag, attrs, kids, state, controls, prev)
  end

  defp render_element(tag, attrs, kids, state, controls, prev) do
    pkids = with {:element, ^tag, _, pkids} <- prev, do: paired(kids, pkids), else: (_ -> nil)

    case render_list(kids, state, controls, pkids) do
      :same ->
        :same

      :prev ->
        case prev do
          {:element, _, pattrs, _} when pattrs === attrs -> :prev
          _ -> {:new, {:element, tag, attrs, pkids}}
        end

      new ->
        {:new, {:element, tag, attrs, the_list(new, kids, pkids)}}
    end
  end

  # an element that holds no control (and so renders as itself), as far as `hot` tells
  defp cold?(_attrs, {_controls, nil}), do: false

  defp cold?(attrs, {_controls, hot}) do
    case List.keyfind(attrs, "@nid", 0) do
      {_, nid} -> not MapSet.member?(hot, nid)
      nil -> false
    end
  end

  @doc """
  The numbers (`@nid`) of the elements in `nodes` that are or hold a control, a `details` or a
  `summary`: the elements whose rendering can change (see `render/5`).
  """
  def hot(nodes), do: nodes |> hot_list(MapSet.new()) |> elem(1)

  defp hot_list(nodes, set) do
    Enum.reduce(nodes, {false, set}, fn node, {any?, set} ->
      {hot?, set} = hot_node(node, set)
      {any? or hot?, set}
    end)
  end

  defp hot_node({:element, tag, attrs, kids}, set) do
    {kids?, set} = hot_list(kids, set)
    hot? = kids? or tag in ~w(input select textarea details summary progress meter)

    case List.keyfind(attrs, "@nid", 0) do
      {_, nid} when hot? -> {true, MapSet.put(set, nid)}
      _ -> {hot?, set}
    end
  end

  defp hot_node(_node, set), do: {false, set}

  defp prev_kids({:element, _, _, kids}), do: kids
  defp prev_kids(_prev), do: nil

  defp summary?({:element, "summary", attrs, _}, cid),
    do: List.keyfind(attrs, "@cid", 0) == {"@cid", cid}

  defp summary?(_node, _cid), do: false

  # the text of `summary::marker`, else a triangle (none with `list-style: none`)
  defp summary_marker(attrs, open?) do
    case List.keyfind(attrs, "@marker", 0) do
      {_, {closed, open}} when closed != nil or open != nil ->
        if(open?, do: open, else: closed) || default_marker(attrs, open?)

      _ ->
        default_marker(attrs, open?)
    end
  end

  defp default_marker(attrs, open?) do
    case List.keyfind(attrs, "@computed", 0) do
      {_, %{"list-style-type" => "none"}} -> nil
      _ -> if open?, do: "▾ ", else: "▸ "
    end
  end

  # The default stylesheet draws `[checked]` boxes blue, but the cascade only sees the
  # attribute. Once the user's choice differs from it, apply the matching look here.
  @grey {118, 118, 118}
  @blue {0, 117, 255}

  defp restyle_checked(attrs, %{type: type, checked: initial}, %{checked: now})
       when type in ["checkbox", "radio"] and initial != now do
    if List.keymember?(attrs, "@content", 0), do: attrs, else: checked_look(attrs, type, now)
  end

  defp restyle_checked(attrs, _control, _cur), do: attrs

  defp checked_look(attrs, type, now) do
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

  defp default_check("checkbox", _attrs, cur), do: [text(if cur.checked, do: "✓", else: @empty)]

  defp default_check("radio", attrs, cur),
    do: if(cur.checked, do: [dot(attrs)], else: [text(@empty)])

  # the chosen colour of a colour input
  defp swatch(value) do
    {r, g, b} = Browser.Pickers.rgb(value)

    computed = %{
      "display" => "block",
      "width" => {:pct, 1.0},
      "height" => {:pct, 1.0},
      "background-color" => {r, g, b}
    }

    {:element, "control-swatch", [{"@computed", computed}], []}
  end

  # the calendar button at the right end of a date field
  defp picker_icon(type) do
    computed = %{
      "display" => "block",
      "float" => "right",
      "width" => 16.0,
      "height" => 16.0,
      "margin-left" => 2.0
    }

    {:element, "canvas",
     [{"@computed", computed}, {"@icon", if(type == "time", do: :clock, else: :calendar)}], []}
  end

  @doc "The types of inputs that open a picker."
  def picker?(%{tag: "input", type: type}),
    do: type in ["color", "date", "datetime-local", "month", "week", "time"]

  def picker?(_control), do: false

  @doc "What a `<progress>` or `<meter>` bar shows: `{:progress, frac | nil}` or `{:meter, frac, level}`."
  def meter_bar("progress", attrs) do
    max = number(attr(attrs, "max"), 1.0)
    max = if max > 0, do: max, else: 1.0

    case number(attr(attrs, "value"), nil) do
      nil -> {:progress, nil}
      value -> {:progress, clamp01(value / max)}
    end
  end

  def meter_bar("meter", attrs) do
    min = number(attr(attrs, "min"), 0.0)
    max = max(number(attr(attrs, "max"), 1.0), min)
    value = number(attr(attrs, "value"), 0.0) |> max(min) |> min(max)
    low = number(attr(attrs, "low"), min) |> max(min) |> min(max)
    high = number(attr(attrs, "high"), max) |> max(low) |> min(max)
    optimum = number(attr(attrs, "optimum"), (min + max) / 2) |> max(min) |> min(max)
    region = fn v -> if(v < low, do: 0, else: if(v > high, do: 2, else: 1)) end

    level =
      case abs(region.(value) - region.(optimum)) do
        0 -> :good
        1 -> :warn
        _ -> :bad
      end

    {:meter, if(max > min, do: clamp01((value - min) / (max - min)), else: 0.0), level}
  end

  defp number(text, default) do
    case Float.parse(String.trim(to_string(text))) do
      {n, _} -> n
      :error -> default
    end
  end

  defp clamp01(f), do: f |> max(0.0) |> min(1.0)

  # the track and the thumb of a range: a canvas as big as the control that the layout draws
  defp range_node(frac, disabled?) do
    computed = %{"display" => "block", "width" => {:pct, 1.0}, "height" => {:pct, 1.0}}
    {:element, "canvas", [{"@computed", computed}, {"@range", {frac, disabled?}}], []}
  end

  defp content(%{tag: "input", type: type}, attrs, cur) do
    placeholder = attr(attrs, "placeholder")

    case type do
      "hidden" ->
        []

      t when t in ["checkbox", "radio"] ->
        case List.keyfind(attrs, "@content", 0) do
          {_, {unchecked, checked}} ->
            [text(if(cur.checked, do: checked, else: unchecked) || @empty)]

          nil ->
            default_check(t, attrs, cur)
        end

      t when t in ["submit", "button", "reset"] ->
        [text(button_label(t, cur.value, has?(attrs, "value")))]

      "image" ->
        [text(first_present([attr(attrs, "alt"), cur.value], "Submit"))]

      "file" ->
        [text("Choose file")]

      "range" ->
        frac = range_frac(cur.value, range_bounds(attrs))
        [range_node(frac, has?(attrs, "disabled"))]

      "color" ->
        [swatch(cur.value)]

      t when t in ["date", "datetime-local", "month", "week", "time"] ->
        [picker_icon(t) | shown(cur.value, cur, placeholder, attrs)]

      "password" ->
        shown(bullets(cur.value), cur, placeholder, attrs)

      _ ->
        shown(cur.value, cur, placeholder, attrs)
    end
  end

  # a textarea scrolls by whole lines
  defp content(%{tag: "textarea"}, attrs, cur) do
    case {cur.value, attr(attrs, "placeholder")} do
      {"", placeholder} ->
        shown("", cur, placeholder, attrs)

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

  # the default labels only stand in for a missing value attribute: `value=""` is an empty label
  defp button_label("submit", "", false), do: "Submit"
  defp button_label("reset", "", false), do: "Reset"
  defp button_label(_type, "", _given?), do: @empty
  defp button_label(_type, value, _given?), do: value

  defp first_present(values, default), do: Enum.find(values, default, &(&1 != ""))

  defp bullets(value), do: String.duplicate("•", String.length(value))

  @doc """
  The text a non-empty single-line field shows, scrolled by `cur.scroll` characters
  (what `render/3` puts in the field, so a changed value needn't be rendered to know it).
  """
  def visible_text(%{type: "password"}, cur), do: cur.value |> bullets() |> scrolled(cur)
  def visible_text(_control, cur), do: scrolled(cur.value, cur)

  defp scrolled(display, %{scroll: scroll}), do: String.slice(display, scroll..-1//1)

  # the text, scrolled by `scroll` characters; an empty control shows its placeholder instead
  defp shown("", _cur, "", _attrs), do: [text(@empty)]

  defp shown("", _cur, placeholder, attrs) do
    style = %{"color" => {117, 117, 117}}

    style =
      case List.keyfind(attrs, "@placeholder", 0) do
        {_, set} -> Map.merge(style, set)
        nil -> style
      end

    # `::placeholder { opacity: 0 }` hides the hint, the way a floating label asks for
    if style["opacity"] == 0.0,
      do: [text(@empty)],
      else: [{:element, "placeholder", [{"@computed", style}], [text(placeholder)]}]
  end

  defp shown(display, %{scroll: scroll}, _placeholder, _attrs) do
    case scrolled(display, %{scroll: scroll}) do
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
  def focusable?(%{inert?: true}), do: false
  def focusable?(%{type: "hidden"}), do: false
  def focusable?(%{tag: "summary"}), do: false
  def focusable?(_control), do: true

  @doc "Control ids in tab order (document order)."
  def focus_order(controls) do
    controls |> Map.values() |> Enum.filter(&focusable?/1) |> Enum.map(& &1.cid) |> Enum.sort()
  end

  @doc "Whether typing edits this control's text."
  def editable?(%{disabled?: true}), do: false
  def editable?(%{inert?: true}), do: false
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

      type when type in ["checkbox", "summary"] ->
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
  def submission(forms, controls, state, fid, clicked, page_url, base \\ nil) do
    form = Map.get(forms, fid, %{action: "", method: ""})
    params = params(controls, state, fid, clicked)
    query = encode(params)

    action =
      if form.action == "",
        do: page_url,
        else: Browser.Fetch.resolve(base || page_url, form.action)

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
