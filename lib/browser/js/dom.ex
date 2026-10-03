defmodule Browser.JS.DOM do
  @moduledoc """
  The page's document for the JavaScript runtime: nodes, events, selectors, `location`,
  `history`, `URLSearchParams` and the `window` and `document` globals.

  The tree lives in the JS process (under `:dom` in its process dictionary) as a map of node
  ids to plain maps. JavaScript sees a node as a host object (see `Browser.JS.Interp.new_host/3`)
  whose reads and writes land in `host_get/3` and `host_put/4`; its methods are natives on the
  shared prototypes. `from_raw/2` builds the tree from the page's parsed HTML and `to_raw/0`
  turns it back into that shape, after which the page is rebuilt (see `Browser.Page.from_raw/2`).

  Things the script did that reach beyond the tree are queued in the outbox for the session:
  `{:history, :push | :replace, url}`, `{:navigate, url}`, `{:reload}`, `{:submit, form}`.
  """

  import Kernel, except: [node: 1]
  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.Interp

  @void ~w(area base br col embed hr img input link meta param source track wbr)

  # ── state ──────────────────────────────────────────────────

  defp st, do: Process.get(:dom)
  defp put_st(s), do: Process.put(:dom, s)

  defp node(nid), do: Map.fetch!(st().nodes, nid)

  defp put_node(n) do
    s = st()
    put_st(%{s | nodes: Map.put(s.nodes, n.id, n), dirty: true})
  end

  defp update_node(nid, fun), do: put_node(fun.(node(nid)))

  defp new_node(fields) do
    s = st()
    id = s.next

    n =
      Map.merge(
        %{
          id: id,
          kind: :element,
          tag: nil,
          attrs: [],
          internal: [],
          props: %{},
          kids: [],
          parent: nil,
          text: ""
        },
        fields
      )

    put_st(%{s | next: id + 1, nodes: Map.put(s.nodes, id, n)})
    id
  end

  @doc "True when the script changed the tree since the last `clean/0`."
  def dirty?, do: st().dirty
  def clean, do: put_st(%{st() | dirty: false})

  @doc "The queued side effects, oldest first; empties the queue."
  def take_outbox do
    s = st()
    put_st(%{s | outbox: []})
    Enum.reverse(s.outbox)
  end

  defp out(item), do: put_st(%{st() | outbox: [item | st().outbox]})

  def url, do: st().url

  @doc "The document node's id."
  def document, do: st().doc

  @doc "A node's data (see `get_attr/2`)."
  def node_data(nid), do: node(nid)

  # ── building the tree ──────────────────────────────────────

  @doc """
  Sets up the document from the page's parsed tree. `info` has `:url`, `:width`, `:height`.
  """
  def init(raw, info) do
    put_st(%{
      nodes: %{},
      next: 1,
      wrappers: %{},
      listeners: %{},
      dirty: false,
      outbox: [],
      url: info.url,
      width: info[:width] || 960,
      height: info[:height] || 658,
      doc: nil,
      state: nil,
      storage: %{},
      usp: 0,
      history_len: 1,
      ce: %{},
      ce_done: MapSet.new(),
      # where the layout put the elements (`Browser.Nids.rects/2`), the window's scroll
      # position, and the size of the page
      rects: %{},
      scroll: {0.0, 0.0},
      content: {0.0, 0.0},
      next_nid: Browser.Nids.max_nid(raw, -1) + 1
    })

    doc = new_node(%{kind: :document})
    s = st()
    put_st(%{s | doc: doc})
    kids = Enum.map(raw, &build(&1, doc))
    update_node_quiet(doc, &%{&1 | kids: kids})
    clean()
    doc
  end

  defp update_node_quiet(nid, fun) do
    s = st()
    put_st(%{s | nodes: Map.put(s.nodes, nid, fun.(node(nid)))})
  end

  defp build({:text, t}, parent), do: new_node(%{kind: :text, text: t, parent: parent})

  defp build({:element, tag, attrs, kids}, parent) do
    {internal, visible} = Enum.split_with(attrs, fn {k, _} -> String.starts_with?(k, "@") end)
    nid = new_node(%{tag: tag, attrs: visible, internal: internal, parent: parent})
    kid_ids = Enum.map(kids, &build(&1, nid))
    update_node_quiet(nid, &%{&1 | kids: kid_ids})
    nid
  end

  @doc "The values of the page's controls, by control id: `%{cid => %{value:, checked:, selected:}}`."
  def apply_controls(controls) do
    for {nid, n} <- st().nodes,
        n.kind == :element,
        {_, cid} <- [List.keyfind(n.internal, "@cid", 0)] do
      case Map.get(controls, cid) do
        nil ->
          :ok

        cur ->
          props =
            n.props
            |> Map.put("value", cur.value)
            |> Map.put("checked", cur.checked)
            |> Map.put("selectedIndex", cur.selected)

          update_node_quiet(nid, &%{&1 | props: props})
      end
    end

    :ok
  end

  @doc "The tree back as the page's parsed HTML (control state written into attributes)."
  def to_raw do
    doc = node(st().doc)
    Enum.map(doc.kids, &export/1)
  end

  @doc """
  The session numbers a page's controls afresh whenever it takes in a new tree, so the
  nodes here take the numbers `Forms.index` gives the exported `raw`.
  """
  def sync_cids(raw) do
    {indexed, _} = Browser.Forms.index(raw)
    sync_kids(node(st().doc).kids, indexed)
    :ok
  end

  defp sync_kids(nids, indexed) when length(nids) == length(indexed),
    do: Enum.zip(nids, indexed) |> Enum.each(fn {nid, i} -> sync_node(nid, i) end)

  defp sync_kids(_, _), do: :ok

  defp sync_node(nid, {:element, tag, attrs, kids}) do
    n = node(nid)

    if n.kind == :element do
      internal =
        case List.keyfind(attrs, "@cid", 0) do
          nil -> List.keydelete(n.internal, "@cid", 0)
          cid -> List.keystore(n.internal, "@cid", 0, cid)
        end

      if internal != n.internal, do: update_node_quiet(nid, &%{&1 | internal: internal})
      if tag not in ["textarea", "select"], do: sync_kids(n.kids, kids)
    end
  end

  defp sync_node(_, _), do: :ok

  defp export(nid) do
    n = node(nid)

    case n.kind do
      :text ->
        {:text, n.text}

      :comment ->
        {:text, ""}

      _ ->
        attrs = export_attrs(n) ++ [{"@nid", ensure_nid(nid)}]
        kids = export_kids(n)
        {:element, n.tag, attrs, kids}
    end
  end

  # the number the layout knows an element by; elements scripts made get one on their way out
  defp ensure_nid(nid) do
    n = node(nid)

    case List.keyfind(n.internal, "@nid", 0) do
      {_, v} ->
        v

      nil ->
        v = st().next_nid
        put_st(%{st() | next_nid: v + 1})
        update_node_quiet(nid, &%{&1 | internal: &1.internal ++ [{"@nid", v}]})
        v
    end
  end

  defp export_attrs(%{tag: "input"} = n) do
    attrs = n.attrs

    attrs =
      case n.props do
        %{"value" => v} when is_binary(v) -> List.keystore(attrs, "value", 0, {"value", v})
        _ -> attrs
      end

    case n.props do
      %{"checked" => true} -> List.keystore(attrs, "checked", 0, {"checked", ""})
      %{"checked" => false} -> List.keydelete(attrs, "checked", 0)
      _ -> attrs
    end
  end

  defp export_attrs(%{tag: "details"} = n) do
    case n.props do
      %{"open" => true} -> List.keystore(n.attrs, "open", 0, {"open", ""})
      %{"open" => false} -> List.keydelete(n.attrs, "open", 0)
      _ -> n.attrs
    end
  end

  defp export_attrs(n), do: n.attrs

  defp export_kids(%{tag: "textarea", props: %{"value" => v}}) when is_binary(v), do: [{:text, v}]

  defp export_kids(%{tag: "select"} = n) do
    selected = n.props["selectedIndex"]

    n.kids
    |> Enum.map(&export/1)
    |> Enum.with_index()
    |> Enum.map(fn
      {{:element, "option", attrs, kids}, i} when is_integer(selected) ->
        attrs = List.keydelete(attrs, "selected", 0)
        attrs = if i == selected, do: attrs ++ [{"selected", ""}], else: attrs
        {:element, "option", attrs, kids}

      {other, _} ->
        other
    end)
  end

  defp export_kids(n), do: Enum.map(n.kids, &export/1)

  # ── layout ─────────────────────────────────────────────────

  @doc "What the layout knows: element boxes, scroll position, page size."
  def set_layout(rects, sx, sy, content) do
    put_st(%{st() | rects: rects, content: content})
    set_scroll(sx, sy)
  end

  @doc "The window scrolled (or a script asked it to): the position scripts read."
  def set_scroll(x, y) do
    x = x * 1.0
    y = y * 1.0
    put_st(%{st() | scroll: {x, y}})

    for {name, v} <- [{"scrollX", x}, {"pageXOffset", x}, {"scrollY", y}, {"pageYOffset", y}],
        do: declare(global(), name, v)

    :ok
  end

  # the box of an element in page coordinates; an element nothing was drawn for takes the
  # top-left corner of its closest ancestor that has one
  defp page_rect(nid) do
    n = node(nid)

    case List.keyfind(n.internal, "@nid", 0) do
      {_, id} ->
        case st().rects do
          %{^id => {x, y, w, h}} -> {x, y, w, h}
          _ -> inherited_rect(n.parent)
        end

      nil ->
        inherited_rect(n.parent)
    end
  end

  defp inherited_rect(nil), do: {0.0, 0.0, 0.0, 0.0}

  defp inherited_rect(parent) do
    case page_rect(parent) do
      {x, y, _, _} -> {x, y, 0.0, 0.0}
    end
  end

  defp scrolling_element?(n), do: n.kind == :document or n.tag in ["html", "body"]

  defp metric(n, key) do
    {x, y, w, h} = page_rect(n.id)
    {sx, sy} = st().scroll
    {cw, ch} = st().content

    value =
      case {key, scrolling_element?(n)} do
        {"scrollTop", true} -> sy
        {"scrollLeft", true} -> sx
        {k, false} when k in ["scrollTop", "scrollLeft"] -> 0
        {"scrollHeight", true} -> max(ch, st().height)
        {"scrollWidth", true} -> max(cw, st().width)
        {"clientHeight", true} -> st().height
        {"clientWidth", true} -> st().width
        {"offsetWidth", _} -> w
        {"clientWidth", _} -> w
        {"scrollWidth", _} -> w
        {"offsetHeight", _} -> h
        {"clientHeight", _} -> h
        {"scrollHeight", _} -> h
        {"offsetTop", _} -> y
        {"offsetLeft", _} -> x
        _ -> 0
      end

    value |> round() |> float()
  end

  defp rect_object(nid) do
    {x, y, w, h} = page_rect(nid)
    {sx, sy} = st().scroll
    left = x - sx
    top = y - sy

    new_object(
      for {k, v} <- [
            {"x", left},
            {"y", top},
            {"width", w},
            {"height", h},
            {"top", top},
            {"left", left},
            {"right", left + w},
            {"bottom", top + h}
          ],
          do: {k, v * 1.0}
    )
  end

  # `scrollTo(x, y)` and `scrollTo({left, top, behavior})`; the session scrolls the page
  defp scroll_args(args, relative?) do
    {x0, y0} = st().scroll

    {x, y} =
      case args do
        [{:obj, _} = o | _] ->
          {opt_num(o, "left", relative?, x0), opt_num(o, "top", relative?, y0)}

        [x, y | _] ->
          {num_arg(x, relative?, x0), num_arg(y, relative?, y0)}

        _ ->
          {x0, y0}
      end

    scroll_to(x, y)
  end

  defp opt_num(o, key, relative?, current) do
    case Interp.get(o, key) do
      :undefined -> current
      v -> num_arg(v, relative?, current)
    end
  end

  defp num_arg(v, relative?, current) do
    n = to_num_or_zero(v)
    if relative?, do: current + n, else: n
  end

  defp to_num_or_zero(v) do
    case to_num(v) do
      n when is_number(n) -> n
      _ -> 0
    end
  end

  defp scroll_to(x, y) do
    x = max(x, 0) * 1.0
    y = max(y, 0) * 1.0
    set_scroll(x, y)
    out({:scroll_to, x, y})
    :undefined
  end

  # ── queries ────────────────────────────────────────────────

  @doc "Every `<script>` element's id, in document order."
  def descendants(nid) do
    Enum.flat_map(node(nid).kids, fn k -> [k | descendants(k)] end)
  end

  defp elements(nid), do: Enum.filter(descendants(nid), &(node(&1).kind == :element))

  @doc "The node id of the n-th `<form>` (the number the page's form index uses), or nil."
  def form_node(fid), do: Enum.at(Enum.filter(elements(st().doc), &(node(&1).tag == "form")), fid)

  @doc "The node id of the element for the page's control `cid`, or nil."
  def control_node(cid) do
    Enum.find(elements(st().doc), fn nid ->
      List.keyfind(node(nid).internal, "@cid", 0) == {"@cid", cid}
    end)
  end

  def get_attr(n, name), do: with({_, v} <- List.keyfind(n.attrs, name, 0), do: v)

  defp attr_or(n, name, default), do: get_attr(n, name) || default

  defp text_content(nid) do
    n = node(nid)

    case n.kind do
      k when k in [:text, :comment] -> n.text
      _ -> n.kids |> Enum.reject(&(node(&1).kind == :comment)) |> Enum.map_join(&text_content/1)
    end
  end

  defp ancestors(nid) do
    case node(nid).parent do
      nil -> []
      p -> [p | ancestors(p)]
    end
  end

  defp parent_element(nid) do
    case node(nid).parent do
      nil -> nil
      p -> if node(p).kind == :element, do: p
    end
  end

  defp siblings(nid) do
    case node(nid).parent do
      nil -> {[], []}
      p -> node(p).kids |> Enum.split_while(&(&1 != nid)) |> then(fn {a, [_ | b]} -> {a, b} end)
    end
  end

  defp element_kids(nid), do: Enum.filter(node(nid).kids, &(node(&1).kind == :element))

  # ── tree changes ───────────────────────────────────────────

  defp detach(nid) do
    n = node(nid)

    if n.parent do
      update_node(n.parent, &%{&1 | kids: List.delete(&1.kids, nid)})
      update_node(nid, &%{&1 | parent: nil})
    end
  end

  # puts `child` into `parent` before `ref` (nil = at the end); a fragment hands over its kids
  defp insert(parent, child, ref) do
    cond do
      child == parent or child in ancestors(parent) ->
        throw_error("HierarchyRequestError", "The new child element contains the parent.")

      node(child).kind == :fragment ->
        kids = node(child).kids
        Enum.each(kids, &insert(parent, &1, ref))

      true ->
        detach(child)
        update_node(child, &%{&1 | parent: parent})

        update_node(parent, fn p ->
          kids =
            case ref && Enum.find_index(p.kids, &(&1 == ref)) do
              nil -> p.kids ++ [child]
              i -> List.insert_at(p.kids, i, child)
            end

          %{p | kids: kids}
        end)

        connect(child)
    end
  end

  defp set_children(nid, kid_ids) do
    for k <- node(nid).kids, do: update_node(k, &%{&1 | parent: nil})
    update_node(nid, &%{&1 | kids: []})
    for k <- kid_ids, do: insert(nid, k, nil)
  end

  defp set_text(nid, text) do
    case node(nid).kind do
      k when k in [:text, :comment] ->
        update_node(nid, &%{&1 | text: text})

      _ ->
        kids = if text == "", do: [], else: [new_node(%{kind: :text, text: text})]
        set_children(nid, kids)
    end
  end

  defp clone(nid, deep?) do
    n = node(nid)

    copy =
      new_node(%{
        kind: n.kind,
        tag: n.tag,
        attrs: n.attrs,
        props: n.props,
        text: n.text
      })

    if deep? do
      for k <- n.kids, do: insert(copy, clone(k, true), nil)
    end

    copy
  end

  defp parse_fragment(html) do
    frag = new_node(%{kind: :fragment})
    for raw <- Browser.HTML.parse(html), do: insert(frag, build(raw, nil), nil)
    node(frag).kids
  end

  defp set_attr(nid, name, value) do
    name = String.downcase(name)
    old_value = nid |> node() |> get_attr(name)
    set_attr_quiet(nid, name, value)
    attribute_changed(nid, name, old_value, value)
  end

  defp set_attr_quiet(nid, name, value) do
    update_node(nid, fn n ->
      n = %{n | attrs: List.keystore(n.attrs, name, 0, {name, value})}

      # the live state follows an attribute only until the script or the user sets it
      case name do
        "value" -> %{n | props: Map.delete(n.props, "value")}
        "checked" -> %{n | props: Map.delete(n.props, "checked")}
        "open" -> %{n | props: Map.delete(n.props, "open")}
        _ -> n
      end
    end)
  end

  defp remove_attr(nid, name) do
    name = String.downcase(name)
    update_node(nid, fn n -> %{n | attrs: List.keydelete(n.attrs, name, 0)} end)
  end

  # ── wrappers ───────────────────────────────────────────────

  @doc "The JavaScript object for a node (the same object every time)."
  def wrap(nid) do
    s = st()

    case s.wrappers do
      %{^nid => w} ->
        w

      _ ->
        proto =
          case node(nid).kind do
            :text -> proto({:dom, :text})
            :comment -> proto({:dom, :text})
            :document -> proto({:dom, :document})
            :fragment -> proto({:dom, :node})
            :element -> proto({:dom, {:tag, node(nid).tag}}) || proto({:dom, :element})
          end

        w = new_host(__MODULE__, nid, proto)
        put_st(%{st() | wrappers: Map.put(st().wrappers, nid, w)})
        w
    end
  end

  defp wrap_or_null(nil), do: :null
  defp wrap_or_null(nid), do: wrap(nid)

  defp nid_of({:obj, id}) do
    case deref(id) do
      %{class: :host, host: {__MODULE__, nid}} when is_integer(nid) -> nid
      _ -> throw_error("TypeError", "parameter is not of type 'Node'.")
    end
  end

  defp nid_of(_), do: throw_error("TypeError", "parameter is not of type 'Node'.")

  defp this_nid(this), do: nid_of(this)

  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp float(n), do: n * 1.0
  defp nodes_array(ids), do: new_array(Enum.map(ids, &wrap/1))

  # ── host protocol: reads ───────────────────────────────────

  @doc false
  def host_get(nid, key, self) when is_integer(nid) do
    n = node(nid)
    node_get(n, key, self)
  end

  def host_get({:classlist, nid}, key, _self), do: classlist_get(nid, key)
  def host_get({:style, nid}, key, _self), do: style_get(nid, key)
  def host_get({:dataset, nid}, key, _self), do: dataset_get(nid, key)
  def host_get(:window, key, _self), do: window_get(key)
  def host_get(:location, key, _self), do: location_get(key)
  def host_get({:usp, k}, key, _self), do: usp_get(k, key)
  def host_get(:storage, key, _self), do: storage_get(key)
  def host_get(:history, "length", _self), do: {:ok, float(st().history_len)}
  def host_get(:history, "state", _self), do: {:ok, st().state || :null}
  def host_get(_other, _key, _self), do: :miss

  defp node_get(n, key, self) do
    case {key, n.kind} do
      {"nodeType", k} ->
        {:ok, float(%{element: 1, text: 3, comment: 8, document: 9, fragment: 11}[k])}

      {"nodeName", :element} ->
        {:ok, String.upcase(n.tag)}

      {"nodeName", :text} ->
        {:ok, "#text"}

      {"nodeName", :comment} ->
        {:ok, "#comment"}

      {"nodeName", :document} ->
        {:ok, "#document"}

      {"nodeName", :fragment} ->
        {:ok, "#document-fragment"}

      {"parentNode", _} ->
        {:ok, wrap_or_null(n.parent)}

      {"parentElement", _} ->
        {:ok, wrap_or_null(parent_element(n.id))}

      {"childNodes", _} ->
        {:ok, nodes_array(n.kids)}

      {"firstChild", _} ->
        {:ok, wrap_or_null(List.first(n.kids))}

      {"lastChild", _} ->
        {:ok, wrap_or_null(List.last(n.kids))}

      {"nextSibling", _} ->
        {:ok, wrap_or_null(elem(siblings(n.id), 1) |> List.first())}

      {"previousSibling", _} ->
        {:ok, wrap_or_null(elem(siblings(n.id), 0) |> List.last())}

      {"nextElementSibling", _} ->
        {:ok, wrap_or_null(sibling_elements(n.id, :next))}

      {"previousElementSibling", _} ->
        {:ok, wrap_or_null(sibling_elements(n.id, :prev))}

      {"firstElementChild", _} ->
        {:ok, wrap_or_null(List.first(element_kids(n.id)))}

      {"lastElementChild", _} ->
        {:ok, wrap_or_null(List.last(element_kids(n.id)))}

      {"children", _} ->
        {:ok, nodes_array(element_kids(n.id))}

      {"childElementCount", _} ->
        {:ok, float(length(element_kids(n.id)))}

      {"textContent", :document} ->
        {:ok, :null}

      {"textContent", _} ->
        {:ok, text_content(n.id)}

      {"nodeValue", k} when k in [:text, :comment] ->
        {:ok, n.text}

      {"data", k} when k in [:text, :comment] ->
        {:ok, n.text}

      {"length", k} when k in [:text, :comment] ->
        {:ok, float(String.length(n.text))}

      {"ownerDocument", _} ->
        {:ok, wrap(st().doc)}

      {"isConnected", _} ->
        {:ok, n.id == st().doc or st().doc in ancestors(n.id)}

      {_, :element} ->
        element_get(n, key, self)

      {_, :document} ->
        document_get(n, key)

      _ ->
        :miss
    end
  end

  defp sibling_elements(nid, dir) do
    {before, aft} = siblings(nid)

    case dir do
      :next -> Enum.find(aft, &(node(&1).kind == :element))
      :prev -> before |> Enum.reverse() |> Enum.find(&(node(&1).kind == :element))
    end
  end

  @bool_attrs ~w(disabled hidden readonly required multiple autofocus selected)

  defp element_get(n, key, _self) do
    case key do
      "tagName" ->
        {:ok, String.upcase(n.tag)}

      "localName" ->
        {:ok, n.tag}

      "id" ->
        {:ok, attr_or(n, "id", "")}

      "className" ->
        {:ok, attr_or(n, "class", "")}

      "classList" ->
        {:ok, aux_host({:classlist, n.id}, :classlist)}

      "style" ->
        {:ok, aux_host({:style, n.id}, :style)}

      "dataset" ->
        {:ok, aux_host({:dataset, n.id}, :dataset)}

      "innerHTML" ->
        {:ok, serialize_kids(n.id)}

      "outerHTML" ->
        {:ok, serialize(n.id)}

      "innerText" ->
        {:ok, text_content(n.id)}

      "value" ->
        {:ok, value_of(n)}

      "checked" ->
        {:ok, checked_of(n)}

      "open" ->
        {:ok, open_of(n)}

      "selectedIndex" ->
        {:ok, float(Map.get(n.props, "selectedIndex") || 0)}

      "type" ->
        {:ok, type_of(n)}

      "form" ->
        {:ok, wrap_or_null(form_of(n.id))}

      "options" when n.tag == "select" ->
        {:ok, nodes_array(Enum.filter(descendants(n.id), &(node(&1).tag == "option")))}

      "attributes" ->
        {:ok,
         new_array(Enum.map(n.attrs, fn {k, v} -> new_object([{"name", k}, {"value", v}]) end))}

      k when k in ~w(offsetWidth offsetHeight offsetTop offsetLeft clientWidth clientHeight
                     clientTop clientLeft scrollWidth scrollHeight scrollTop scrollLeft) ->
        {:ok, metric(n, k)}

      "tabIndex" ->
        {:ok, -1.0}

      k when k in @bool_attrs ->
        {:ok, get_attr(n, k) != nil}

      k
      when k in ~w(href src name placeholder title alt action method target rel for lang dir role) ->
        {:ok, attr_or(n, k, "")}

      "htmlFor" ->
        {:ok, attr_or(n, "for", "")}

      "content" when n.tag == "template" ->
        {:ok, :undefined}

      _ ->
        :miss
    end
  end

  defp value_of(%{tag: "textarea"} = n), do: Map.get(n.props, "value") || text_content(n.id)

  defp value_of(%{tag: "select"} = n) do
    options = Enum.filter(descendants(n.id), &(node(&1).tag == "option"))

    sel =
      n.props["selectedIndex"] ||
        Enum.find_index(options, &(get_attr(node(&1), "selected") != nil)) || 0

    case Enum.at(options, sel) do
      nil -> ""
      o -> option_value(node(o))
    end
  end

  defp value_of(%{tag: "option"} = n), do: option_value(n)
  defp value_of(n), do: Map.get(n.props, "value") || attr_or(n, "value", "")

  defp option_value(n), do: get_attr(n, "value") || text_content(n.id)

  defp checked_of(n) do
    case n.props do
      %{"checked" => c} -> c
      _ -> get_attr(n, "checked") != nil
    end
  end

  defp open_of(n) do
    case n.props do
      %{"open" => o} -> o
      _ -> get_attr(n, "open") != nil
    end
  end

  defp type_of(%{tag: "input"} = n), do: String.downcase(attr_or(n, "type", "text"))
  defp type_of(%{tag: "button"} = n), do: String.downcase(attr_or(n, "type", "submit"))
  defp type_of(n), do: attr_or(n, "type", "")

  defp form_of(nid) do
    Enum.find(ancestors(nid), &(node(&1).tag == "form"))
  end

  defp document_get(_n, key) do
    s = st()

    case key do
      "body" ->
        {:ok, wrap_or_null(find_tag(s.doc, "body"))}

      "head" ->
        {:ok, wrap_or_null(find_tag(s.doc, "head"))}

      "documentElement" ->
        root =
          find_tag(s.doc, "html") ||
            Enum.find(node(s.doc).kids, &(node(&1).kind == :element))

        {:ok, wrap_or_null(root)}

      "title" ->
        {:ok,
         find_tag(s.doc, "title")
         |> then(&if(&1, do: text_content(&1), else: ""))
         |> String.trim()}

      "location" ->
        {:ok, aux_host(:location, :location)}

      "defaultView" ->
        {:ok, aux_host(:window, :window)}

      "readyState" ->
        {:ok, "complete"}

      "cookie" ->
        {:ok, ""}

      "referrer" ->
        {:ok, ""}

      "URL" ->
        {:ok, s.url}

      "documentURI" ->
        {:ok, s.url}

      "characterSet" ->
        {:ok, "UTF-8"}

      "contentType" ->
        {:ok, "text/html"}

      "activeElement" ->
        {:ok, wrap_or_null(find_tag(s.doc, "body"))}

      "hidden" ->
        {:ok, false}

      "visibilityState" ->
        {:ok, "visible"}

      _ ->
        :miss
    end
  end

  defp find_tag(nid, tag), do: Enum.find(descendants(nid), &(node(&1).tag == tag))

  # ── host protocol: writes ──────────────────────────────────

  @doc false
  def host_put(nid, key, v, _self) when is_integer(nid) do
    n = node(nid)
    node_put(n, key, v)
  end

  def host_put({:style, nid}, key, v, _), do: style_put(nid, key, v)
  def host_put({:dataset, nid}, key, v, _), do: dataset_put(nid, key, v)
  def host_put(:window, key, v, _), do: window_put(key, v)
  def host_put(:location, key, v, _), do: location_put(key, v)
  def host_put(:storage, key, v, _), do: storage_put(key, v)
  def host_put(_other, _key, _v, _self), do: :miss

  defp node_put(n, key, v) do
    case {key, n.kind} do
      {"textContent", k} when k != :document ->
        set_text(n.id, to_str_or_empty(v))
        :ok

      {k, kind} when k in ["nodeValue", "data"] and kind in [:text, :comment] ->
        set_text(n.id, to_str(v))
        :ok

      {_, :element} ->
        element_put(n, key, v)

      {"title", :document} ->
        set_title(to_str(v))
        :ok

      _ ->
        :miss
    end
  end

  defp to_str_or_empty(v) when v in [:null, :undefined], do: ""
  defp to_str_or_empty(v), do: to_str(v)

  defp element_put(n, key, v) do
    nid = n.id

    case key do
      "id" ->
        set_attr(nid, "id", to_str(v))
        :ok

      "className" ->
        set_attr(nid, "class", to_str(v))
        :ok

      k when k in ["scrollTop", "scrollLeft"] ->
        if scrolling_element?(n) do
          {x, y} = st().scroll
          num = to_num_or_zero(v)
          if k == "scrollTop", do: scroll_to(x, num), else: scroll_to(num, y)
        end

        :ok

      "innerHTML" ->
        set_children(nid, parse_fragment(to_str_or_empty(v)))
        :ok

      "outerHTML" ->
        replace_with(nid, parse_fragment(to_str(v)))
        :ok

      "innerText" ->
        set_text(nid, to_str_or_empty(v))
        :ok

      "value" ->
        update_node(nid, &%{&1 | props: Map.put(&1.props, "value", to_str_or_empty(v))})
        :ok

      "checked" ->
        update_node(nid, &%{&1 | props: Map.put(&1.props, "checked", truthy(v))})
        :ok

      "open" ->
        update_node(nid, &%{&1 | props: Map.put(&1.props, "open", truthy(v))})
        :ok

      "selectedIndex" ->
        update_node(nid, &%{&1 | props: Map.put(&1.props, "selectedIndex", to_int(v))})
        :ok

      "style" ->
        set_attr(nid, "style", to_str(v))
        :ok

      "htmlFor" ->
        set_attr(nid, "for", to_str(v))
        :ok

      k when k in @bool_attrs ->
        if truthy(v), do: set_attr(nid, k, ""), else: remove_attr(nid, k)
        :ok

      k
      when k in ~w(href src name placeholder title alt action method target rel lang dir role type) ->
        set_attr(nid, k, to_str(v))
        :ok

      "on" <> event ->
        if function?(v),
          do: set_inline_handler(nid, event, v),
          else: set_inline_handler(nid, event, nil)

        :ok

      _ ->
        :miss
    end
  end

  defp set_title(text) do
    s = st()

    case find_tag(s.doc, "title") do
      nil ->
        with head when head != nil <- find_tag(s.doc, "head") do
          t = new_node(%{tag: "title"})
          set_text(t, text)
          insert(head, t, nil)
        end

      t ->
        set_text(t, text)
    end
  end

  defp replace_with(nid, new_ids) do
    case node(nid).parent do
      nil ->
        :ok

      p ->
        ref = elem(siblings(nid), 1) |> List.first()
        detach(nid)
        for k <- new_ids, do: insert(p, k, ref)
    end
  end

  # ── classList, style, dataset ──────────────────────────────

  defp aux_host(data, kind) do
    s = st()
    key = {:aux, data}

    case s.wrappers do
      %{^key => w} ->
        w

      _ ->
        w = new_host(__MODULE__, data, proto({:dom, kind}))
        put_st(%{st() | wrappers: Map.put(st().wrappers, key, w)})
        w
    end
  end

  defp classes(nid), do: nid |> node() |> attr_or("class", "") |> String.split()

  defp put_classes(nid, list) do
    set_attr(nid, "class", Enum.join(Enum.uniq(list), " "))
  end

  defp classlist_get(nid, "length"), do: {:ok, float(length(classes(nid)))}
  defp classlist_get(nid, "value"), do: {:ok, attr_or(node(nid), "class", "")}
  defp classlist_get(_nid, _), do: :miss

  defp style_decls(nid) do
    node(nid)
    |> attr_or("style", "")
    |> String.split(";")
    |> Enum.flat_map(fn d ->
      case String.split(d, ":", parts: 2) do
        [k, v] -> [{String.trim(k) |> String.downcase(), String.trim(v)}]
        _ -> []
      end
    end)
  end

  defp put_style_decls(nid, decls) do
    css = Enum.map_join(decls, " ", fn {k, v} -> "#{k}: #{v};" end)
    if css == "", do: remove_attr(nid, "style"), else: set_attr(nid, "style", css)
  end

  defp kebab(name) do
    name
    |> String.replace(~r/[A-Z]/, fn c -> "-" <> String.downcase(c) end)
    |> then(fn k -> if String.starts_with?(k, "css-float"), do: "float", else: k end)
  end

  defp style_get(nid, "cssText"), do: {:ok, attr_or(node(nid), "style", "")}
  defp style_get(nid, "length"), do: {:ok, float(length(style_decls(nid)))}

  defp style_get(nid, key) do
    if key in ~w(setProperty getPropertyValue removeProperty item),
      do: :miss,
      else:
        {:ok,
         style_decls(nid)
         |> List.keyfind(kebab(key), 0)
         |> then(&if(&1, do: elem(&1, 1), else: ""))}
  end

  defp style_put(nid, "cssText", v) do
    set_attr(nid, "style", to_str(v))
    :ok
  end

  defp style_put(nid, key, v) do
    set_style(nid, kebab(key), to_str_or_empty(v))
    :ok
  end

  defp set_style(nid, prop, ""),
    do: put_style_decls(nid, List.keydelete(style_decls(nid), prop, 0))

  defp set_style(nid, prop, value),
    do: put_style_decls(nid, List.keystore(style_decls(nid), prop, 0, {prop, value}))

  defp dataset_key(key), do: "data-" <> kebab(key)

  defp dataset_get(nid, key) do
    case get_attr(node(nid), dataset_key(key)) do
      nil -> {:ok, :undefined}
      v -> {:ok, v}
    end
  end

  defp dataset_put(nid, key, v) do
    set_attr(nid, dataset_key(key), to_str(v))
    :ok
  end

  # ── events ─────────────────────────────────────────────────

  defp add_listener(target, type, fun, opts) do
    {capture, once} =
      case opts do
        true -> {true, false}
        {:obj, _} -> {truthy(Interp.get(opts, "capture")), truthy(Interp.get(opts, "once"))}
        _ -> {false, false}
      end

    s = st()
    list = Map.get(s.listeners, target, [])

    unless Enum.any?(list, &(&1.type == type and &1.fun == fun and &1.capture == capture)) do
      l = %{type: type, fun: fun, capture: capture, once: once}
      put_st(%{s | listeners: Map.put(s.listeners, target, list ++ [l])})
    end
  end

  defp remove_listener(target, type, fun, capture) do
    s = st()
    list = Map.get(s.listeners, target, [])
    list = Enum.reject(list, &(&1.type == type and &1.fun == fun and &1.capture == capture))
    put_st(%{s | listeners: Map.put(s.listeners, target, list)})
  end

  # `el.onclick = fn`: one slot per event type, kept among the listeners
  defp set_inline_handler(target, type, fun) do
    s = st()
    list = Enum.reject(Map.get(s.listeners, target, []), &(&1.type == type and &1[:inline]))

    list =
      if fun,
        do: list ++ [%{type: type, fun: fun, capture: false, once: false, inline: true}],
        else: list

    put_st(%{s | listeners: Map.put(s.listeners, target, list)})
  end

  defp target_obj(:window), do: aux_host(:window, :window)
  defp target_obj(nid), do: wrap(nid)

  @doc """
  Fires an event at `target` (a node id or `:window`): capture phase down from the window,
  the target, then bubbling back up. `init` is `%{prop => JS value}` for the event object plus
  `:bubbles`/`:cancelable`. Returns `:prevented` or `:ok`.
  """
  def dispatch(target, type, init \\ %{}) do
    bubbles = Map.get(init, :bubbles, true)
    cancelable = Map.get(init, :cancelable, true)

    event =
      new_object(
        [
          {"type", type},
          {"target", target_obj(target)},
          {"currentTarget", :null},
          {"defaultPrevented", false},
          {"bubbles", bubbles},
          {"cancelable", cancelable},
          {"eventPhase", 0.0},
          {"isTrusted", true},
          {"timeStamp", float(System.monotonic_time(:millisecond))}
        ] ++
          for({k, v} <- init, is_binary(k), do: {k, v}),
        proto({:dom, :event})
      )

    path =
      case target do
        :window -> [:window]
        nid -> [nid | ancestors(nid)] ++ [:window]
      end

    # capture: from the outermost down to the target's parent
    outer_first = path |> tl() |> Enum.reverse()

    result =
      catch_stop(fn ->
        Enum.each(outer_first, &fire(&1, event, :capture))
        fire(hd(path), event, :at_target)
        if bubbles, do: Enum.each(tl(path), &fire(&1, event, :bubble))
      end)

    _ = result
    put(event, "currentTarget", :null)
    put(event, "eventPhase", 0.0)
    if truthy(Interp.get(event, "defaultPrevented")), do: :prevented, else: :ok
  end

  defp put(o, k, v), do: Interp.put(o, k, v)

  defp catch_stop(fun) do
    fun.()
    :done
  catch
    :dom_stop -> :stopped
  end

  defp fire(target, event, phase) do
    listeners = Map.get(st().listeners, target, [])
    type = Interp.get(event, "type")

    for l <- listeners, l.type == type, phase_matches?(l, phase) do
      if l.once, do: remove_listener(target, type, l.fun, l.capture)
      put(event, "currentTarget", target_obj(target))
      put(event, "eventPhase", %{capture: 1.0, at_target: 2.0, bubble: 3.0}[phase])

      try do
        case l.fun do
          f when is_tuple(f) ->
            if function?(f),
              do: call(f, target_obj(target), [event]),
              else: call(Interp.get(f, "handleEvent"), f, [event])
        end
      catch
        {:js_error, v} -> console_error("Uncaught " <> describe(v))
      end

      if truthy(Interp.get(event, "__stop_immediate")), do: throw(:dom_stop)
    end

    if truthy(Interp.get(event, "__stop")), do: throw(:dom_stop)
    :ok
  end

  defp phase_matches?(l, :capture), do: l.capture
  defp phase_matches?(l, :bubble), do: not l.capture
  defp phase_matches?(_l, :at_target), do: true

  defp describe(v) when is_binary(v), do: v

  defp describe({:obj, _} = v) do
    case Interp.get(v, "message") do
      m when is_binary(m) -> m
      _ -> Browser.JS.Builtins.inspect_js(v, 0, [])
    end
  end

  defp describe(v), do: Browser.JS.Builtins.inspect_js(v, 0, [])

  defp console_error(text),
    do: Process.put(:js_console, [{:error, text} | Process.get(:js_console, [])])

  # ── selectors ──────────────────────────────────────────────

  # a selector list: [[{combinator, compound}, ...], ...], leftmost first
  defp parse_selectors(str) do
    str
    |> split_top(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_complex/1)
  end

  defp split_top(str, sep), do: split_top(String.graphemes(str), sep, 0, nil, [], [])

  defp split_top([], _sep, _d, _q, cur, acc),
    do: Enum.reverse([cur |> Enum.reverse() |> Enum.join() | acc])

  defp split_top([c | rest], sep, d, q, cur, acc) do
    cond do
      q != nil ->
        split_top(rest, sep, d, if(c == q, do: nil, else: q), [c | cur], acc)

      c in ["\"", "'"] ->
        split_top(rest, sep, d, c, [c | cur], acc)

      c in ["(", "["] ->
        split_top(rest, sep, d + 1, q, [c | cur], acc)

      c in [")", "]"] ->
        split_top(rest, sep, d - 1, q, [c | cur], acc)

      c == sep and d == 0 ->
        split_top(rest, sep, d, q, [], [cur |> Enum.reverse() |> Enum.join() | acc])

      true ->
        split_top(rest, sep, d, q, [c | cur], acc)
    end
  end

  defp parse_complex(str) do
    tokens = complex_tokens(String.graphemes(String.trim(str)), 0, nil, [], [])
    build_complex(tokens, " ", [])
  end

  # compounds and combinators in order
  defp complex_tokens([], _d, _q, cur, acc), do: Enum.reverse(flush_token(cur, acc))

  defp complex_tokens([c | rest], d, q, cur, acc) do
    cond do
      q != nil ->
        complex_tokens(rest, d, if(c == q, do: nil, else: q), [c | cur], acc)

      c in ["\"", "'"] ->
        complex_tokens(rest, d, c, [c | cur], acc)

      c in ["(", "["] ->
        complex_tokens(rest, d + 1, q, [c | cur], acc)

      c in [")", "]"] ->
        complex_tokens(rest, d - 1, q, [c | cur], acc)

      d == 0 and c in [">", "+", "~"] ->
        complex_tokens(rest, d, q, [], [{:comb, c} | flush_token(cur, acc)])

      d == 0 and c in [" ", "\t", "\n"] ->
        complex_tokens(rest, d, q, [], flush_token(cur, acc))

      true ->
        complex_tokens(rest, d, q, [c | cur], acc)
    end
  end

  defp flush_token([], acc), do: acc
  defp flush_token(cur, acc), do: [{:compound, cur |> Enum.reverse() |> Enum.join()} | acc]

  defp build_complex([], _comb, acc), do: Enum.reverse(acc)
  defp build_complex([{:comb, c} | rest], _comb, acc), do: build_complex(rest, c, acc)

  defp build_complex([{:compound, s} | rest], comb, acc),
    do: build_complex(rest, " ", [{comb, parse_compound(s)} | acc])

  @compound_re ~r/(\*|[a-zA-Z][\w-]*)|#([\w-]+)|\.([\w-]+)|\[([^\]]*)\]|:([\w-]+)(\((?:[^()]|\([^()]*\))*\))?/

  defp parse_compound(s) do
    @compound_re
    |> Regex.scan(s)
    |> Enum.map(fn
      [_, tag] when tag != "" -> {:tag, String.downcase(tag)}
      [_, "", id] -> {:id, id}
      [_, "", "", cls] -> {:class, cls}
      [_, "", "", "", attr] -> {:attr, parse_attr(attr)}
      [_, "", "", "", "", pseudo] -> {:pseudo, pseudo, nil}
      [_, "", "", "", "", pseudo, arg] -> {:pseudo, pseudo, String.slice(arg, 1..-2//1)}
      other -> {:unknown, other}
    end)
  end

  defp parse_attr(s) do
    case Regex.run(
           ~r/^\s*([\w:-]+)\s*(?:([~|^$*]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s\]]*))\s*(i)?)?\s*$/,
           s
         ) do
      nil ->
        {s, nil, nil}

      [_, name] ->
        {String.downcase(name), nil, nil}

      [_, name, op | vals] ->
        {String.downcase(name), op, vals |> Enum.take(3) |> Enum.find("", &(&1 != ""))}
    end
  end

  defp matches?(nid, selectors),
    do: node(nid).kind == :element and Enum.any?(selectors, &match_complex(nid, Enum.reverse(&1)))

  # `parts` is rightmost first
  defp match_complex(nid, [{_comb, compound}]), do: match_compound(nid, compound)

  defp match_complex(nid, [{comb, compound} | rest]) do
    match_compound(nid, compound) and
      case comb do
        " " -> Enum.any?(ancestors(nid), &(node(&1).kind == :element and match_complex(&1, rest)))
        ">" -> (p = parent_element(nid)) != nil and match_complex(p, rest)
        "+" -> (s = sibling_elements(nid, :prev)) != nil and match_complex(s, rest)
        "~" -> Enum.any?(prev_elements(nid), &match_complex(&1, rest))
      end
  end

  defp prev_elements(nid) do
    {before, _} = siblings(nid)
    before |> Enum.filter(&(node(&1).kind == :element))
  end

  defp match_compound(nid, conds) do
    n = node(nid)
    Enum.all?(conds, &match_cond(n, &1))
  end

  defp match_cond(n, {:tag, "*"}), do: n.kind == :element
  defp match_cond(n, {:tag, t}), do: n.tag == t
  defp match_cond(n, {:id, id}), do: get_attr(n, "id") == id
  defp match_cond(n, {:class, c}), do: c in (n |> attr_or("class", "") |> String.split())

  defp match_cond(n, {:attr, {name, op, val}}) do
    case get_attr(n, name) do
      nil -> false
      v -> attr_match(op, v, val)
    end
  end

  defp match_cond(n, {:pseudo, "first-child", _}),
    do: List.first(element_kids(n.parent || -1)) == n.id

  defp match_cond(n, {:pseudo, "last-child", _}),
    do: List.last(element_kids(n.parent || -1)) == n.id

  defp match_cond(n, {:pseudo, "only-child", _}), do: element_kids(n.parent || -1) == [n.id]
  defp match_cond(n, {:pseudo, "empty", _}), do: n.kids == []
  defp match_cond(n, {:pseudo, "checked", _}), do: checked_of(n) == true
  defp match_cond(n, {:pseudo, "disabled", _}), do: get_attr(n, "disabled") != nil
  defp match_cond(n, {:pseudo, "enabled", _}), do: get_attr(n, "disabled") == nil
  defp match_cond(n, {:pseudo, "root", _}), do: n.tag == "html"
  defp match_cond(n, {:pseudo, "not", arg}), do: not matches?(n.id, parse_selectors(arg))
  defp match_cond(n, {:pseudo, "is", arg}), do: matches?(n.id, parse_selectors(arg))
  defp match_cond(n, {:pseudo, "where", arg}), do: matches?(n.id, parse_selectors(arg))
  defp match_cond(_n, {:pseudo, _, _}), do: false
  defp match_cond(_n, _), do: false

  defp attr_match(nil, _v, _), do: true
  defp attr_match("=", v, val), do: v == val
  defp attr_match("~=", v, val), do: val in String.split(v)
  defp attr_match("|=", v, val), do: v == val or String.starts_with?(v, val <> "-")
  defp attr_match("^=", v, val), do: val != "" and String.starts_with?(v, val)
  defp attr_match("$=", v, val), do: val != "" and String.ends_with?(v, val)
  defp attr_match("*=", v, val), do: val != "" and String.contains?(v, val)

  defp query_all(root, selector) do
    sels = parse_selectors(selector)
    Enum.filter(elements(root), &matches?(&1, sels))
  end

  # ── serialising ────────────────────────────────────────────

  defp serialize(nid) do
    n = node(nid)

    case n.kind do
      :text ->
        escape_text(n.text, parent_tag(n))

      :comment ->
        "<!--" <> n.text <> "-->"

      :document ->
        serialize_kids(nid)

      :fragment ->
        serialize_kids(nid)

      :element ->
        attrs =
          Enum.map_join(export_attrs(n), fn {k, v} ->
            " " <> k <> "=\"" <> escape_attr(v) <> "\""
          end)

        if n.tag in @void,
          do: "<#{n.tag}#{attrs}>",
          else: "<#{n.tag}#{attrs}>#{serialize_kids(nid)}</#{n.tag}>"
    end
  end

  defp serialize_kids(nid), do: node(nid).kids |> Enum.map_join(&serialize/1)

  defp parent_tag(n), do: n.parent && node(n.parent).tag

  defp escape_text(t, tag) when tag in ["script", "style"], do: t

  defp escape_text(t, _),
    do:
      t
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp escape_attr(v), do: v |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;")

  # ── window, location, history ──────────────────────────────

  defp window_get(key) do
    s = st()

    case key do
      k when k in ["window", "self", "top", "parent", "globalThis", "frames"] ->
        {:ok, aux_host(:window, :window)}

      "document" ->
        {:ok, wrap(s.doc)}

      "location" ->
        {:ok, aux_host(:location, :location)}

      "history" ->
        {:ok, aux_host(:history, :history)}

      "innerWidth" ->
        {:ok, float(s.width)}

      "innerHeight" ->
        {:ok, float(s.height)}

      "outerWidth" ->
        {:ok, float(s.width)}

      "outerHeight" ->
        {:ok, float(s.height)}

      "devicePixelRatio" ->
        {:ok, 1.0}

      k when k in ["scrollX", "pageXOffset"] ->
        {:ok, elem(s.scroll, 0)}

      k when k in ["scrollY", "pageYOffset"] ->
        {:ok, elem(s.scroll, 1)}

      "localStorage" ->
        {:ok, aux_host(:storage, :storage)}

      "sessionStorage" ->
        {:ok, aux_host(:storage, :storage)}

      "navigator" ->
        {:ok, Process.get(:dom_navigator, :undefined)}

      _ ->
        # a global variable: `window.foo` is `foo`
        case Map.fetch(deref(global()).vars, key) do
          {:ok, v} -> {:ok, v}
          :error -> :miss
        end
    end
  end

  defp window_put(key, v) do
    if key == "location" do
      location_put("href", v)
    else
      declare(global(), key, v)
      :ok
    end
  end

  defp url_parts do
    uri = URI.parse(st().url)
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    %{uri: uri, path: path, query: uri.query, fragment: uri.fragment}
  end

  defp location_get(key) do
    p = url_parts()
    uri = p.uri

    case key do
      "href" ->
        {:ok, st().url}

      "pathname" ->
        {:ok, p.path}

      "search" ->
        {:ok, if(p.query in [nil, ""], do: "", else: "?" <> p.query)}

      "hash" ->
        {:ok, if(p.fragment in [nil, ""], do: "", else: "#" <> p.fragment)}

      "protocol" ->
        {:ok, (uri.scheme || "about") <> ":"}

      "hostname" ->
        {:ok, uri.host || ""}

      "host" ->
        {:ok, host_with_port(uri)}

      "port" ->
        {:ok,
         if(uri.port && uri.port != URI.default_port(uri.scheme),
           do: Integer.to_string(uri.port),
           else: ""
         )}

      "origin" ->
        {:ok,
         if(uri.host, do: (uri.scheme || "http") <> "://" <> host_with_port(uri), else: "null")}

      _ ->
        :miss
    end
  end

  defp host_with_port(uri) do
    if uri.port && uri.port != URI.default_port(uri.scheme),
      do: "#{uri.host}:#{uri.port}",
      else: uri.host || ""
  end

  defp location_put("href", v) do
    out({:navigate, resolve_url(to_str(v))})
    :ok
  end

  defp location_put("search", v) do
    out({:navigate, resolve_url("?" <> String.trim_leading(to_str(v), "?"))})
    :ok
  end

  defp location_put("hash", v) do
    set_url(resolve_url("#" <> String.trim_leading(to_str(v), "#")))
    out({:history, :push, st().url})
    :ok
  end

  defp location_put(_, _), do: :miss

  defp resolve_url(href), do: Browser.Fetch.resolve(st().url, href)

  defp set_url(url), do: put_st(%{st() | url: url})

  # ── Storage ────────────────────────────────────────────────

  defp storage_get(key) do
    case key do
      "length" -> {:ok, float(map_size(st().storage))}
      k when k in ~w(getItem setItem removeItem clear key) -> :miss
      k -> {:ok, Map.get(st().storage, k, :undefined)}
    end
  end

  defp storage_put(key, v) do
    put_st(%{st() | storage: Map.put(st().storage, key, to_str(v))})
    :ok
  end

  # ── URLSearchParams ────────────────────────────────────────

  defp usp_pairs(k), do: Process.get({:usp, k}, [])
  defp usp_set(k, pairs), do: Process.put({:usp, k}, pairs)

  defp usp_get(k, "size"), do: {:ok, float(length(usp_pairs(k)))}
  defp usp_get(_, _), do: :miss

  defp new_usp(pairs) do
    s = st()
    k = s.usp
    put_st(%{s | usp: k + 1})
    usp_set(k, pairs)
    new_host(__MODULE__, {:usp, k}, proto({:dom, :usp}))
  end

  defp usp_key({:obj, id}) do
    case deref(id) do
      %{class: :host, host: {__MODULE__, {:usp, k}}} -> k
      _ -> throw_error("TypeError", "Illegal invocation")
    end
  end

  defp parse_query(q) do
    q
    |> String.trim_leading("?")
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {decode_component(k), decode_component(v)}
        [k] -> {decode_component(k), ""}
      end
    end)
  end

  defp decode_component(s), do: s |> String.replace("+", " ") |> URI.decode()

  defp encode_query(pairs),
    do:
      Enum.map_join(pairs, "&", fn {k, v} ->
        URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v)
      end)

  @doc false
  def encode_pairs(pairs), do: encode_query(pairs)

  # ── custom elements ────────────────────────────────────────

  defp registered(tag), do: Map.get(st().ce, tag)

  defp set_proto({:obj, id}, proto), do: store(id, %{deref(id) | proto: proto})

  defp connected?(nid), do: nid == st().doc or st().doc in ancestors(nid)

  # an element that is in the document gets upgraded, or told it was connected again
  defp connect(nid) do
    if st().ce != %{} and connected?(nid) do
      for e <- [nid | elements(nid)], node(e).kind == :element, ctor = registered(node(e).tag) do
        if MapSet.member?(st().ce_done, e) do
          call_callback(e, "connectedCallback", [])
        else
          upgrade(e, ctor)
        end
      end
    end

    :ok
  end

  defp upgrade(nid, ctor) do
    put_st(%{st() | ce_done: MapSet.put(st().ce_done, nid)})
    w = wrap(nid)
    set_proto(w, Interp.get(ctor, "prototype"))
    Process.put(:ce_upgrading, w)

    try do
      construct(ctor, [], ctor)
    catch
      {:js_error, v} -> console_error("Uncaught " <> describe(v))
    after
      Process.delete(:ce_upgrading)
    end

    for name <- observed(ctor), (v = get_attr(node(nid), name)) != nil do
      call_callback(nid, "attributeChangedCallback", [name, :null, v])
    end

    if connected?(nid), do: call_callback(nid, "connectedCallback", [])
  end

  defp observed(ctor) do
    case Interp.get(ctor, "observedAttributes") do
      {:obj, _} = list -> if array?(list), do: Enum.map(array_list(list), &to_str/1), else: []
      _ -> []
    end
  end

  defp call_callback(nid, name, args) do
    w = wrap(nid)

    case Interp.get(w, name) do
      f when is_tuple(f) ->
        if function?(f) do
          try do
            call(f, w, args)
          catch
            {:js_error, v} -> console_error("Uncaught " <> describe(v))
          end
        end

      _ ->
        :ok
    end
  end

  defp attribute_changed(nid, name, old, new) do
    if MapSet.member?(st().ce_done, nid) do
      tag = node(nid).tag

      with ctor when ctor != nil <- registered(tag), true <- name in observed(ctor) do
        call_callback(nid, "attributeChangedCallback", [name, old || :null, new])
      end
    end

    :ok
  end

  defp define_element(name, ctor) do
    name = String.downcase(to_str(name))

    unless function?(ctor),
      do: throw_error("TypeError", "The custom element constructor is not a function")

    unless String.contains?(name, "-"),
      do: throw_error("SyntaxError", "'#{name}' is not a valid custom element name")

    if registered(name),
      do: throw_error("NotSupportedError", "'#{name}' has already been used with this registry")

    put_st(%{st() | ce: Map.put(st().ce, name, ctor)})

    for e <- elements(st().doc), node(e).tag == name, do: upgrade(e, ctor)
    :ok
  end

  # `new X()` for a registered constructor, or the element being upgraded
  defp html_element_ctor(this) do
    case Process.get(:ce_upgrading) do
      nil ->
        proto =
          case this do
            {:obj, id} -> deref(id).proto
            _ -> nil
          end

        tag =
          Enum.find_value(st().ce, fn {name, c} ->
            if proto != nil and Interp.get(c, "prototype") == proto, do: name
          end)

        if tag == nil, do: throw_error("TypeError", "Illegal constructor")
        nid = new_node(%{tag: tag})
        put_st(%{st() | ce_done: MapSet.put(st().ce_done, nid)})
        wrap(nid)

      w ->
        w
    end
  end

  # ── install ────────────────────────────────────────────────

  @doc "Defines the DOM prototypes and the `window`, `document`, ... globals."
  def install(scope) do
    object = proto(:object)
    event_target = new_object([], object)
    node_proto = new_object([], event_target)
    element = new_object([], node_proto)
    text = new_object([], node_proto)
    document = new_object([], node_proto)
    event = new_object([], object)

    put_proto({:dom, :node}, node_proto)
    put_proto({:dom, :element}, element)
    put_proto({:dom, :text}, text)
    put_proto({:dom, :document}, document)
    put_proto({:dom, :event}, event)
    put_proto({:dom, :classlist}, new_object([], object))
    put_proto({:dom, :style}, new_object([], object))
    put_proto({:dom, :dataset}, new_object([], object))
    put_proto({:dom, :location}, new_object([], object))
    put_proto({:dom, :history}, new_object([], object))
    put_proto({:dom, :storage}, new_object([], object))
    put_proto({:dom, :usp}, new_object([], object))
    put_proto({:dom, :window}, new_object([], event_target))

    install_event_target(event_target)
    install_node(node_proto)
    install_element(element)
    install_document(document)
    install_event(event)
    install_aux()
    install_globals(scope, event_target, node_proto, element, text, document, event)
    :ok
  end

  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))

  defp ctor(scope, name, proto, fun) do
    f = native(name, fun)
    put_hidden(f, "prototype", proto)
    put_hidden(proto, "constructor", f)
    declare(scope, name, f)
    f
  end

  defp install_event_target(p) do
    def_fn(p, "addEventListener", fn this, args ->
      if function?(arg(args, 1)) or match?({:obj, _}, arg(args, 1)),
        do: add_listener(listener_target(this), to_str(arg(args, 0)), arg(args, 1), arg(args, 2))

      :undefined
    end)

    def_fn(p, "removeEventListener", fn this, args ->
      capture =
        case arg(args, 2) do
          true -> true
          {:obj, _} = o -> truthy(Interp.get(o, "capture"))
          _ -> false
        end

      remove_listener(listener_target(this), to_str(arg(args, 0)), arg(args, 1), capture)
      :undefined
    end)

    def_fn(p, "dispatchEvent", fn this, args ->
      ev = arg(args, 0)

      init = %{
        bubbles: truthy(Interp.get(ev, "bubbles")),
        cancelable: truthy(Interp.get(ev, "cancelable"))
      }

      extra =
        for k <- own_keys(ev),
            k not in ~w(type target currentTarget defaultPrevented bubbles cancelable eventPhase isTrusted timeStamp),
            into: %{},
            do: {k, Interp.get(ev, k)}

      r = dispatch(listener_target(this), to_str(Interp.get(ev, "type")), Map.merge(extra, init))
      r == :ok
    end)
  end

  defp listener_target({:obj, id} = this) do
    case deref(id) do
      %{class: :host, host: {__MODULE__, :window}} -> :window
      _ -> this_nid(this)
    end
  end

  defp install_node(p) do
    def_fn(p, "appendChild", fn this, args ->
      child = nid_of(arg(args, 0))
      insert(this_nid(this), child, nil)
      arg(args, 0)
    end)

    def_fn(p, "insertBefore", fn this, args ->
      ref = if arg(args, 1) in [:null, :undefined], do: nil, else: nid_of(arg(args, 1))
      insert(this_nid(this), nid_of(arg(args, 0)), ref)
      arg(args, 0)
    end)

    def_fn(p, "removeChild", fn this, args ->
      child = nid_of(arg(args, 0))

      if node(child).parent != this_nid(this),
        do: throw_error("NotFoundError", "The node to be removed is not a child of this node.")

      detach(child)
      arg(args, 0)
    end)

    def_fn(p, "replaceChild", fn this, args ->
      new = nid_of(arg(args, 0))
      old = nid_of(arg(args, 1))
      ref = elem(siblings(old), 1) |> List.first()
      parent = this_nid(this)
      detach(old)
      insert(parent, new, ref)
      arg(args, 1)
    end)

    def_fn(p, "cloneNode", fn this, args -> wrap(clone(this_nid(this), truthy(arg(args, 0)))) end)
    def_fn(p, "hasChildNodes", fn this, _ -> node(this_nid(this)).kids != [] end)

    def_fn(p, "contains", fn this, args ->
      other = arg(args, 0)

      other != :null and
        (nid_of(other) == this_nid(this) or this_nid(this) in ancestors(nid_of(other)))
    end)

    def_fn(p, "isSameNode", fn this, args -> this_nid(this) == nid_of(arg(args, 0)) end)
    def_fn(p, "getRootNode", fn _this, _ -> wrap(st().doc) end)
    def_fn(p, "normalize", fn _this, _ -> :undefined end)

    def_fn(p, "remove", fn this, _ ->
      detach(this_nid(this))
      :undefined
    end)

    # ParentNode / ChildNode conveniences
    def_fn(p, "append", fn this, args ->
      for a <- args, do: insert(this_nid(this), to_node(a), nil)
      :undefined
    end)

    def_fn(p, "prepend", fn this, args ->
      first = List.first(node(this_nid(this)).kids)
      for a <- args, do: insert(this_nid(this), to_node(a), first)
      :undefined
    end)

    def_fn(p, "replaceChildren", fn this, args ->
      set_children(this_nid(this), Enum.map(args, &to_node/1))
      :undefined
    end)

    def_fn(p, "before", fn this, args ->
      nid = this_nid(this)

      if parent = node(nid).parent do
        for a <- args, do: insert(parent, to_node(a), nid)
      end

      :undefined
    end)

    def_fn(p, "after", fn this, args ->
      nid = this_nid(this)

      if parent = node(nid).parent do
        ref = elem(siblings(nid), 1) |> List.first()
        for a <- args, do: insert(parent, to_node(a), ref)
      end

      :undefined
    end)

    def_fn(p, "replaceWith", fn this, args ->
      nid = this_nid(this)

      if parent = node(nid).parent do
        ref = elem(siblings(nid), 1) |> List.first()
        detach(nid)
        for a <- args, do: insert(parent, to_node(a), ref)
      end

      :undefined
    end)

    def_fn(p, "querySelector", fn this, args ->
      wrap_or_null(List.first(query_all(this_nid(this), to_str(arg(args, 0)))))
    end)

    def_fn(p, "querySelectorAll", fn this, args ->
      nodes_array(query_all(this_nid(this), to_str(arg(args, 0))))
    end)

    def_fn(p, "getElementsByTagName", fn this, args ->
      tag = String.downcase(to_str(arg(args, 0)))
      nodes_array(Enum.filter(elements(this_nid(this)), &(tag == "*" or node(&1).tag == tag)))
    end)

    def_fn(p, "getElementsByClassName", fn this, args ->
      wanted = String.split(to_str(arg(args, 0)))

      nodes_array(
        Enum.filter(elements(this_nid(this)), fn e -> Enum.all?(wanted, &(&1 in classes(e))) end)
      )
    end)
  end

  # a string is a text node
  defp to_node(v) when is_binary(v), do: new_node(%{kind: :text, text: v})
  defp to_node(v) when is_number(v), do: new_node(%{kind: :text, text: to_str(v)})
  defp to_node(v), do: nid_of(v)

  defp install_element(p) do
    def_fn(p, "getAttribute", fn this, args ->
      case get_attr(node(this_nid(this)), String.downcase(to_str(arg(args, 0)))) do
        nil -> :null
        v -> v
      end
    end)

    def_fn(p, "setAttribute", fn this, args ->
      set_attr(this_nid(this), to_str(arg(args, 0)), to_str(arg(args, 1)))
      :undefined
    end)

    def_fn(p, "hasAttribute", fn this, args ->
      get_attr(node(this_nid(this)), String.downcase(to_str(arg(args, 0)))) != nil
    end)

    def_fn(p, "removeAttribute", fn this, args ->
      remove_attr(this_nid(this), to_str(arg(args, 0)))
      :undefined
    end)

    def_fn(p, "toggleAttribute", fn this, args ->
      name = String.downcase(to_str(arg(args, 0)))
      has = get_attr(node(this_nid(this)), name) != nil
      want = if arg(args, 1) == :undefined, do: not has, else: truthy(arg(args, 1))
      if want, do: set_attr(this_nid(this), name, ""), else: remove_attr(this_nid(this), name)
      want
    end)

    def_fn(p, "getAttributeNames", fn this, _ ->
      new_array(Enum.map(node(this_nid(this)).attrs, &elem(&1, 0)))
    end)

    def_fn(p, "matches", fn this, args ->
      matches?(this_nid(this), parse_selectors(to_str(arg(args, 0))))
    end)

    def_fn(p, "closest", fn this, args ->
      sels = parse_selectors(to_str(arg(args, 0)))
      nid = this_nid(this)
      wrap_or_null(Enum.find([nid | ancestors(nid)], &matches?(&1, sels)))
    end)

    def_fn(p, "insertAdjacentElement", fn this, args ->
      adjacent(this_nid(this), to_str(arg(args, 0)), [nid_of(arg(args, 1))])
      arg(args, 1)
    end)

    def_fn(p, "insertAdjacentHTML", fn this, args ->
      adjacent(this_nid(this), to_str(arg(args, 0)), parse_fragment(to_str(arg(args, 1))))
      :undefined
    end)

    def_fn(p, "insertAdjacentText", fn this, args ->
      adjacent(this_nid(this), to_str(arg(args, 0)), [
        new_node(%{kind: :text, text: to_str(arg(args, 1))})
      ])

      :undefined
    end)

    for name <- ~w(focus blur select showModal close) do
      def_fn(p, name, fn _this, _ -> :undefined end)
    end

    # scrolling an element's own contents is not supported; the page itself is
    for name <- ~w(scrollTo scroll scrollBy) do
      def_fn(p, name, fn _this, _ -> :undefined end)
    end

    def_fn(p, "scrollIntoView", fn this, args ->
      {x, y, _, h} = page_rect(this_nid(this))
      {_, sy} = st().scroll
      view = st().height

      block =
        case arg(args, 0) do
          {:obj, _} = o -> Interp.get(o, "block")
          _ -> :undefined
        end

      target =
        case block do
          "end" -> y + h - view
          "center" -> y + h / 2 - view / 2
          "nearest" when y >= sy and y + h <= sy + view -> sy
          "nearest" when y < sy -> y
          "nearest" -> y + h - view
          _ -> y
        end

      _ = x
      scroll_to(elem(st().scroll, 0), target)
    end)

    def_fn(p, "click", fn this, _ ->
      dispatch(this_nid(this), "click", %{})
      :undefined
    end)

    def_fn(p, "submit", fn this, _ ->
      out({:submit, this_nid(this)})
      :undefined
    end)

    def_fn(p, "requestSubmit", fn this, _ ->
      nid = this_nid(this)
      if dispatch(nid, "submit", %{}) == :ok, do: out({:submit, nid})
      :undefined
    end)

    def_fn(p, "reset", fn _this, _ -> :undefined end)

    def_fn(p, "getBoundingClientRect", fn this, _ -> rect_object(this_nid(this)) end)

    def_fn(p, "getClientRects", fn this, _ ->
      case page_rect(this_nid(this)) do
        {_, _, w, h} when w == 0 and h == 0 -> new_array([])
        _ -> new_array([rect_object(this_nid(this))])
      end
    end)

    def_fn(p, "animate", fn _this, _ -> new_object([]) end)
  end

  defp adjacent(nid, position, ids) do
    n = node(nid)

    case position do
      "beforebegin" ->
        if n.parent, do: Enum.each(ids, &insert(n.parent, &1, nid))

      "afterbegin" ->
        first = List.first(n.kids)
        Enum.each(ids, &insert(nid, &1, first))

      "beforeend" ->
        Enum.each(ids, &insert(nid, &1, nil))

      "afterend" ->
        if n.parent do
          ref = elem(siblings(nid), 1) |> List.first()
          Enum.each(ids, &insert(n.parent, &1, ref))
        end

      _ ->
        throw_error(
          "SyntaxError",
          "The value provided ('#{position}') is not one of 'beforebegin', 'afterbegin', 'beforeend', or 'afterend'."
        )
    end
  end

  defp install_document(p) do
    def_fn(p, "getElementById", fn _this, args ->
      id = to_str(arg(args, 0))
      wrap_or_null(Enum.find(elements(st().doc), &(get_attr(node(&1), "id") == id)))
    end)

    def_fn(p, "createElement", fn _this, args ->
      tag = args |> arg(0) |> to_str() |> String.downcase()

      case registered(tag) do
        nil -> wrap(new_node(%{tag: tag}))
        ctor -> construct(ctor, [], ctor)
      end
    end)

    def_fn(p, "createTextNode", fn _this, args ->
      wrap(new_node(%{kind: :text, text: to_str(arg(args, 0))}))
    end)

    def_fn(p, "createComment", fn _this, args ->
      wrap(new_node(%{kind: :comment, text: to_str(arg(args, 0))}))
    end)

    def_fn(p, "createDocumentFragment", fn _this, _ -> wrap(new_node(%{kind: :fragment})) end)

    def_fn(p, "createEvent", fn _this, _ ->
      new_object([], proto({:dom, :event}))
    end)

    def_fn(p, "hasFocus", fn _this, _ -> true end)
    def_fn(p, "execCommand", fn _this, _ -> false end)
  end

  defp install_event(p) do
    def_fn(p, "preventDefault", fn this, _ ->
      if truthy(Interp.get(this, "cancelable")), do: put(this, "defaultPrevented", true)
      :undefined
    end)

    def_fn(p, "stopPropagation", fn this, _ ->
      put_hidden(this, "__stop", true)
      :undefined
    end)

    def_fn(p, "stopImmediatePropagation", fn this, _ ->
      put_hidden(this, "__stop", true)
      put_hidden(this, "__stop_immediate", true)
      :undefined
    end)

    def_fn(p, "composedPath", fn _this, _ -> new_array([]) end)
    def_fn(p, "initEvent", fn _this, _ -> :undefined end)
  end

  defp install_aux do
    cl = proto({:dom, :classlist})

    def_fn(cl, "add", fn this, args ->
      nid = classlist_nid(this)
      put_classes(nid, classes(nid) ++ Enum.map(args, &to_str/1))
      :undefined
    end)

    def_fn(cl, "remove", fn this, args ->
      nid = classlist_nid(this)
      drop = Enum.map(args, &to_str/1)
      put_classes(nid, Enum.reject(classes(nid), &(&1 in drop)))
      :undefined
    end)

    def_fn(cl, "contains", fn this, args ->
      to_str(arg(args, 0)) in classes(classlist_nid(this))
    end)

    def_fn(cl, "toggle", fn this, args ->
      nid = classlist_nid(this)
      c = to_str(arg(args, 0))
      has = c in classes(nid)
      want = if arg(args, 1) == :undefined, do: not has, else: truthy(arg(args, 1))

      put_classes(
        nid,
        if(want, do: classes(nid) ++ [c], else: Enum.reject(classes(nid), &(&1 == c)))
      )

      want
    end)

    def_fn(cl, "replace", fn this, args ->
      nid = classlist_nid(this)
      old = to_str(arg(args, 0))
      new = to_str(arg(args, 1))
      has = old in classes(nid)
      if has, do: put_classes(nid, Enum.map(classes(nid), &if(&1 == old, do: new, else: &1)))
      has
    end)

    def_fn(cl, "item", fn this, args ->
      Enum.at(classes(classlist_nid(this)), to_int(arg(args, 0)), :null)
    end)

    def_fn(cl, "toString", fn this, _ -> attr_or(node(classlist_nid(this)), "class", "") end)

    def_fn(cl, "forEach", fn this, args ->
      for {c, i} <- Enum.with_index(classes(classlist_nid(this))),
          do: call(arg(args, 0), :undefined, [c, float(i)])

      :undefined
    end)

    sp = proto({:dom, :style})

    def_fn(sp, "setProperty", fn this, args ->
      set_style(
        style_nid(this),
        String.downcase(to_str(arg(args, 0))),
        to_str_or_empty(arg(args, 1))
      )

      :undefined
    end)

    def_fn(sp, "getPropertyValue", fn this, args ->
      style_decls(style_nid(this))
      |> List.keyfind(String.downcase(to_str(arg(args, 0))), 0)
      |> then(&if(&1, do: elem(&1, 1), else: ""))
    end)

    def_fn(sp, "removeProperty", fn this, args ->
      nid = style_nid(this)
      prop = String.downcase(to_str(arg(args, 0)))
      old = style_decls(nid) |> List.keyfind(prop, 0) |> then(&if(&1, do: elem(&1, 1), else: ""))
      set_style(nid, prop, "")
      old
    end)

    loc = proto({:dom, :location})

    def_fn(loc, "assign", fn _this, args ->
      out({:navigate, resolve_url(to_str(arg(args, 0)))})
      :undefined
    end)

    def_fn(loc, "replace", fn _this, args ->
      out({:navigate, resolve_url(to_str(arg(args, 0)))})
      :undefined
    end)

    def_fn(loc, "reload", fn _this, _ ->
      out({:reload})
      :undefined
    end)

    def_fn(loc, "toString", fn _this, _ -> st().url end)

    hist = proto({:dom, :history})

    def_fn(hist, "pushState", fn _this, args -> history_state(args, :push) end)
    def_fn(hist, "replaceState", fn _this, args -> history_state(args, :replace) end)

    for {name, dir} <- [{"back", -1}, {"forward", 1}] do
      def_fn(hist, name, fn _this, _ ->
        out({:history_go, dir})
        :undefined
      end)
    end

    def_fn(hist, "go", fn _this, args ->
      out({:history_go, to_int(arg(args, 0))})
      :undefined
    end)

    storage = proto({:dom, :storage})

    def_fn(storage, "getItem", fn _this, args ->
      Map.get(st().storage, to_str(arg(args, 0)), :null)
    end)

    def_fn(storage, "setItem", fn _this, args ->
      put_st(%{st() | storage: Map.put(st().storage, to_str(arg(args, 0)), to_str(arg(args, 1)))})
      :undefined
    end)

    def_fn(storage, "removeItem", fn _this, args ->
      put_st(%{st() | storage: Map.delete(st().storage, to_str(arg(args, 0)))})
      :undefined
    end)

    def_fn(storage, "clear", fn _this, _ ->
      put_st(%{st() | storage: %{}})
      :undefined
    end)

    def_fn(storage, "key", fn _this, args ->
      st().storage |> Map.keys() |> Enum.sort() |> Enum.at(to_int(arg(args, 0)), :null)
    end)

    install_usp(proto({:dom, :usp}))

    win = proto({:dom, :window})

    for name <- ~w(alert focus blur print) do
      def_fn(win, name, fn _this, _ -> :undefined end)
    end

    def_fn(win, "scrollTo", fn _this, args -> scroll_args(args, false) end)
    def_fn(win, "scroll", fn _this, args -> scroll_args(args, false) end)
    def_fn(win, "scrollBy", fn _this, args -> scroll_args(args, true) end)
  end

  defp history_state(args, kind) do
    case arg(args, 2) do
      v when v in [:undefined, :null] ->
        :ok

      v ->
        url = resolve_url(to_str(v))
        set_url(url)
        out({:history, kind, url})
    end

    if kind == :push, do: put_st(%{st() | history_len: st().history_len + 1})
    put_st(%{st() | state: arg(args, 0)})
    :undefined
  end

  defp classlist_nid({:obj, id}),
    do: with(%{host: {__MODULE__, {:classlist, nid}}} <- deref(id), do: nid)

  defp style_nid({:obj, id}), do: with(%{host: {__MODULE__, {:style, nid}}} <- deref(id), do: nid)

  defp install_usp(p) do
    def_fn(p, "get", fn this, args ->
      case List.keyfind(usp_pairs(usp_key(this)), to_str(arg(args, 0)), 0) do
        nil -> :null
        {_, v} -> v
      end
    end)

    def_fn(p, "getAll", fn this, args ->
      k = to_str(arg(args, 0))
      new_array(for {pk, v} <- usp_pairs(usp_key(this)), pk == k, do: v)
    end)

    def_fn(p, "has", fn this, args ->
      List.keymember?(usp_pairs(usp_key(this)), to_str(arg(args, 0)), 0)
    end)

    def_fn(p, "set", fn this, args ->
      key = usp_key(this)
      name = to_str(arg(args, 0))
      value = to_str(arg(args, 1))
      pairs = usp_pairs(key)

      pairs =
        if List.keymember?(pairs, name, 0) do
          {out, _} =
            Enum.flat_map_reduce(pairs, false, fn {k, v}, done ->
              cond do
                k != name -> {[{k, v}], done}
                done -> {[], true}
                true -> {[{name, value}], true}
              end
            end)

          out
        else
          pairs ++ [{name, value}]
        end

      usp_set(key, pairs)
      :undefined
    end)

    def_fn(p, "append", fn this, args ->
      key = usp_key(this)
      usp_set(key, usp_pairs(key) ++ [{to_str(arg(args, 0)), to_str(arg(args, 1))}])
      :undefined
    end)

    def_fn(p, "delete", fn this, args ->
      key = usp_key(this)
      name = to_str(arg(args, 0))
      usp_set(key, Enum.reject(usp_pairs(key), &(elem(&1, 0) == name)))
      :undefined
    end)

    def_fn(p, "sort", fn this, _ ->
      key = usp_key(this)
      usp_set(key, Enum.sort_by(usp_pairs(key), &elem(&1, 0)))
      :undefined
    end)

    def_fn(p, "toString", fn this, _ -> encode_query(usp_pairs(usp_key(this))) end)

    def_fn(p, "forEach", fn this, args ->
      for {k, v} <- usp_pairs(usp_key(this)), do: call(arg(args, 0), :undefined, [v, k, this])
      :undefined
    end)

    def_fn(p, "keys", fn this, _ -> new_array(for {k, _} <- usp_pairs(usp_key(this)), do: k) end)

    def_fn(p, "values", fn this, _ -> new_array(for {_, v} <- usp_pairs(usp_key(this)), do: v) end)

    def_fn(p, "entries", fn this, _ ->
      new_array(for {k, v} <- usp_pairs(usp_key(this)), do: new_array([k, v]))
    end)
  end

  @element_classes [
    {"HTMLAnchorElement", ["a"]},
    {"HTMLAreaElement", ["area"]},
    {"HTMLFormElement", ["form"]},
    {"HTMLInputElement", ["input"]},
    {"HTMLTextAreaElement", ["textarea"]},
    {"HTMLButtonElement", ["button"]},
    {"HTMLSelectElement", ["select"]},
    {"HTMLOptionElement", ["option"]},
    {"HTMLImageElement", ["img"]},
    {"HTMLScriptElement", ["script"]},
    {"HTMLLinkElement", ["link"]},
    {"HTMLStyleElement", ["style"]},
    {"HTMLDivElement", ["div"]},
    {"HTMLSpanElement", ["span"]},
    {"HTMLBodyElement", ["body"]},
    {"HTMLHtmlElement", ["html"]},
    {"HTMLTemplateElement", ["template"]},
    {"HTMLLabelElement", ["label"]},
    {"HTMLIFrameElement", ["iframe"]},
    {"HTMLDialogElement", ["dialog"]},
    {"HTMLCanvasElement", ["canvas"]},
    {"HTMLVideoElement", ["video"]},
    {"HTMLAudioElement", ["audio"]},
    {"HTMLTableElement", ["table"]},
    {"HTMLUListElement", ["ul"]},
    {"HTMLOListElement", ["ol"]},
    {"HTMLLIElement", ["li"]},
    {"HTMLParagraphElement", ["p"]},
    {"HTMLHeadingElement", ["h1", "h2", "h3", "h4", "h5", "h6"]},
    {"HTMLPreElement", ["pre"]},
    {"HTMLMetaElement", ["meta"]},
    {"HTMLHeadElement", ["head"]},
    {"HTMLTitleElement", ["title"]},
    {"HTMLBRElement", ["br"]},
    {"HTMLHRElement", ["hr"]},
    {"HTMLDetailsElement", ["details"]},
    {"HTMLFieldSetElement", ["fieldset"]},
    {"HTMLLegendElement", ["legend"]},
    {"HTMLOptGroupElement", ["optgroup"]},
    {"HTMLProgressElement", ["progress"]}
  ]

  defp install_globals(scope, event_target, node_proto, element, text, document, event) do
    # constructors, so `instanceof` works (and `new Event(...)`)
    ctor(scope, "EventTarget", event_target, fn _, _ -> :undefined end)
    ctor(scope, "Node", node_proto, fn _, _ -> :undefined end)
    ctor(scope, "Element", element, fn _, _ -> :undefined end)
    ctor(scope, "HTMLElement", element, fn this, _ -> html_element_ctor(this) end)
    # `el instanceof HTMLAnchorElement` and the like
    for {name, tags} <- @element_classes do
      p = new_object([], element)
      for tag <- tags, do: put_proto({:dom, {:tag, tag}}, p)
      ctor(scope, name, p, fn _, _ -> throw_error("TypeError", "Illegal constructor") end)
    end

    for name <- ~w(SVGElement SVGAElement ShadowRoot DocumentFragment Comment KeyframeEffect) do
      ctor(scope, name, new_object([], element), fn _, _ -> :undefined end)
    end

    ctor(scope, "Text", text, fn _, _ -> :undefined end)
    ctor(scope, "Document", document, fn _, _ -> :undefined end)

    make_event = fn _this, args ->
      init = arg(args, 1)

      opt = fn k ->
        if match?({:obj, _}, init), do: truthy(Interp.get(init, k)), else: false
      end

      ev =
        new_object(
          [
            {"type", to_str(arg(args, 0))},
            {"target", :null},
            {"currentTarget", :null},
            {"defaultPrevented", false},
            {"bubbles", opt.("bubbles")},
            {"cancelable", opt.("cancelable")},
            {"eventPhase", 0.0},
            {"isTrusted", false},
            {"timeStamp", float(System.monotonic_time(:millisecond))}
          ],
          event
        )

      if match?({:obj, _}, init) do
        for k <- own_keys(init),
            k not in ["bubbles", "cancelable"],
            do: put(ev, k, Interp.get(init, k))
      end

      ev
    end

    for name <- ~w(Event CustomEvent MouseEvent KeyboardEvent InputEvent SubmitEvent FocusEvent) do
      ctor(scope, name, event, make_event)
    end

    url_proto = new_object()

    ctor(scope, "URL", url_proto, fn _this, args ->
      raw = to_str(arg(args, 0))

      uri =
        case arg(args, 1) do
          b when b in [:undefined, :null] -> URI.parse(raw)
          b -> URI.merge(URI.parse(to_str(b)), raw)
        end

      unless uri.scheme && (uri.host || uri.scheme in ~w(data blob mailto javascript about)),
        do: throw_error("TypeError", "Invalid URL: " <> raw)

      path = if uri.path in [nil, ""] and uri.host, do: "/", else: uri.path || ""
      host = uri.host || ""

      port =
        if uri.port && uri.port != URI.default_port(uri.scheme),
          do: Integer.to_string(uri.port),
          else: ""

      query = if uri.query in [nil, ""], do: "", else: "?" <> uri.query
      hash = if uri.fragment in [nil, ""], do: "", else: "#" <> uri.fragment
      hostport = if port == "", do: host, else: host <> ":" <> port
      origin = if uri.host, do: uri.scheme <> "://" <> hostport, else: "null"

      href =
        if uri.host,
          do: origin <> path <> query <> hash,
          else: uri.scheme <> ":" <> path <> query <> hash

      usp = deref_global("URLSearchParams")
      params = construct(usp, [String.trim_leading(query, "?")], usp)

      obj =
        new_object([
          {"href", href},
          {"origin", origin},
          {"protocol", uri.scheme <> ":"},
          {"username", ""},
          {"password", ""},
          {"host", hostport},
          {"hostname", host},
          {"port", port},
          {"pathname", path},
          {"search", query},
          {"hash", hash},
          {"searchParams", params}
        ])

      set_proto(obj, url_proto)
      obj
    end)

    for name <- ~w(toString toJSON) do
      def_fn(url_proto, name, fn this, _ -> Interp.get(this, "href") end)
    end

    usp =
      ctor(scope, "URLSearchParams", proto({:dom, :usp}), fn _this, args ->
        init = arg(args, 0)

        pairs =
          cond do
            init in [:undefined, :null] ->
              []

            is_binary(init) ->
              parse_query(init)

            array?(init) ->
              for p <- array_list(init),
                  do: {to_str(Interp.get(p, 0.0)), to_str(Interp.get(p, 1.0))}

            match?({:obj, _}, init) ->
              case deref(elem(init, 1)) do
                %{class: :host, host: {__MODULE__, {:usp, k}}} -> usp_pairs(k)
                _ -> for k <- own_keys(init), do: {k, to_str(Interp.get(init, k))}
              end

            true ->
              parse_query(to_str(init))
          end

        new_usp(pairs)
      end)

    _ = usp

    registry = new_object()
    declare(scope, "customElements", registry)

    def_fn(registry, "define", fn _, args ->
      define_element(arg(args, 0), arg(args, 1))
      :undefined
    end)

    def_fn(registry, "get", fn _, args ->
      registered(String.downcase(to_str(arg(args, 0)))) || :undefined
    end)

    def_fn(registry, "whenDefined", fn _, _ ->
      p = Browser.JS.Promise.new()
      Browser.JS.Promise.resolve(p, :undefined)
      p
    end)

    def_fn(registry, "upgrade", fn _, _ -> :undefined end)

    # globals that point into the document
    window = aux_host(:window, :window)
    declare(scope, "window", window)
    declare(scope, "self", window)
    declare(scope, "globalThis", window)
    declare(scope, "document", wrap(st().doc))
    declare(scope, "location", aux_host(:location, :location))
    declare(scope, "history", aux_host(:history, :history))
    declare(scope, "localStorage", aux_host(:storage, :storage))
    declare(scope, "sessionStorage", aux_host(:storage, :storage))

    for {name, v} <- [
          {"innerWidth", float(st().width)},
          {"innerHeight", float(st().height)},
          {"outerWidth", float(st().width)},
          {"outerHeight", float(st().height)},
          {"devicePixelRatio", 1.0},
          {"scrollX", 0.0},
          {"scrollY", 0.0},
          {"pageXOffset", 0.0},
          {"pageYOffset", 0.0}
        ] do
      declare(scope, name, v)
    end

    for name <- ~w(alert focus blur print) do
      declare(scope, name, native(name, fn _, _ -> :undefined end))
    end

    for {name, relative?} <- [{"scrollTo", false}, {"scroll", false}, {"scrollBy", true}] do
      declare(scope, name, native(name, fn _, args -> scroll_args(args, relative?) end))
    end

    # `addEventListener(...)` without `window.` is the window's
    for name <- ~w(addEventListener removeEventListener dispatchEvent) do
      declare(
        scope,
        name,
        native(name, fn _, args ->
          call(Interp.get(proto({:dom, :window}), name), window, args)
        end)
      )
    end

    navigator =
      new_object([
        {"userAgent", "ElixirBrowser/0.1"},
        {"language", "en-US"},
        {"languages", new_array(["en-US"])},
        {"platform", "MacIntel"},
        {"onLine", true}
      ])

    Process.put(:dom_navigator, navigator)
    declare(scope, "navigator", navigator)

    declare(
      scope,
      "getComputedStyle",
      native("getComputedStyle", fn _, args ->
        el = arg(args, 0)
        aux_host({:style, nid_of(el)}, :style)
      end)
    )

    declare(
      scope,
      "matchMedia",
      native("matchMedia", fn _, args ->
        new_object([
          {"matches", false},
          {"media", to_str(arg(args, 0))},
          {"addEventListener", native("addEventListener", fn _, _ -> :undefined end)},
          {"removeEventListener", native("removeEventListener", fn _, _ -> :undefined end)}
        ])
      end)
    )

    declare(
      scope,
      "requestAnimationFrame",
      native("requestAnimationFrame", fn _, args ->
        st = Interp.get(deref_global("setTimeout"), "call")
        _ = st
        call(deref_global("setTimeout"), :undefined, [arg(args, 0), 0.0])
      end)
    )

    :ok
  end

  defp deref_global(name) do
    case Map.fetch(deref(global()).vars, name) do
      {:ok, v} -> v
      :error -> :undefined
    end
  end
end
