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
  `{:history, :push | :replace, url}`, `{:navigate, url}`, `{:open_tab, url}`, `{:reload}`, `{:submit, form}`.
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

    s =
      if n.doc == s.main or n.doc == nil,
        do: %{s | dirty: true},
        else: %{s | fdirty: MapSet.put(s.fdirty, n.doc)}

    put_st(%{s | nodes: Map.put(s.nodes, n.id, n), rev: s.rev + 1})
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
          text: "",
          # a `<template>`'s content: the fragment that holds what is inside it
          content: nil,
          # the document the node belongs to (a document node's is itself)
          doc: s.doc
        },
        fields
      )

    # (the checks that frames need are only made once the page has an <iframe>)
    if n.tag == "iframe", do: Process.put(:dom_has_iframe, true)
    put_st(%{s | next: id + 1, nodes: Map.put(s.nodes, id, n), rev: s.rev + 1})
    id
  end

  @doc "True when the script changed the tree since the last `clean/0`."
  def dirty?, do: st().dirty
  def clean, do: put_st(%{st() | dirty: false, fdirty: MapSet.new()})

  @doc "The documents of frames that scripts changed since the last `clean/0`."
  def changed_frames, do: st().fdirty

  # ── realms: the page, and the documents of its frames ──────
  #
  # A frame has a document, a window with its own global scope, location and history. They all
  # live in this process and share the node table, so a script of the page reaches into a frame
  # (`frame.contentDocument.body`) as into its own document. What belongs to one document
  # alone (`@realm_fields` here, `@realm_keys` of the process dictionary) is swapped in while
  # that document is the one running (`in_realm/2`); the rest of the state is shared.

  @realm_fields ~w(doc url hist hist_idx history_before scroll_restoration width height scroll
                   content rects current_script storage_origin ce ce_done write_after)a
  @realm_keys ~w(js_global js_global_fixed js_global_lex js_modules js_import rt_info rt_importmap
                 rt_seen_scripts rt_prefetched rt_script)a

  defp take_keys, do: Map.new(@realm_keys, &{&1, Process.get(&1, :__unset)})

  defp put_keys(keys) do
    Enum.each(keys, fn
      {k, :__unset} -> Process.delete(k)
      {k, v} -> Process.put(k, v)
    end)
  end

  @doc """
  Runs `fun` with the document `doc` (a frame's, or the page's) as the running one: `window`,
  `document`, `location` and the global scope are its own while `fun` runs.
  """
  def in_realm(doc, fun) do
    s = st()

    cond do
      doc == nil or doc == s.doc -> fun.()
      not is_map_key(s.realms, doc) -> fun.()
      true -> enter_realm(doc, fun)
    end
  end

  defp enter_realm(doc, fun) do
    prev = swap_realm(doc)

    try do
      fun.()
    after
      swap_realm(prev)
      # a script that took its own frame away: what it left in the table goes with it
      if Process.get(:dom_dead) == doc do
        Process.delete(:dom_dead)
        put_st(%{st() | realms: Map.delete(st().realms, doc)})
      end
    end
  end

  # makes `doc` the running document; returns the one that was
  defp swap_realm(doc) do
    s = st()
    prev = s.doc
    %{fields: fields, keys: keys} = Map.fetch!(s.realms, doc)
    saved = %{fields: Map.take(s, @realm_fields), keys: take_keys()}
    realms = s.realms |> Map.delete(doc) |> Map.put(prev, saved)
    put_st(Map.merge(%{s | realms: realms}, fields))
    put_keys(keys)
    prev
  end

  @doc "The frame document a timer made now belongs to (nil in the page's own document)."
  def timer_realm do
    case Process.get(:dom) do
      %{doc: d, main: m} when d != m -> d
      _ -> nil
    end
  end

  @doc "False for the document of a frame that has gone."
  def realm_alive?(nil), do: true
  def realm_alive?(doc), do: is_map_key(st().realms, doc) or st().doc == doc

  @doc "True when the page has frames."
  def frames?, do: map_size(st().realms) > 0

  @doc "The page's own document."
  def main_doc, do: st().main

  @doc "The document of the running realm."
  def current_doc, do: st().doc

  @doc "The documents of every realm, the page's first."
  def realm_docs, do: [st().main | st().frames |> Map.values() |> Enum.sort()]

  @doc "The document of the frame held by the `<iframe>` element, or nil."
  def frame_doc(iframe), do: Map.get(st().frames, iframe)

  @doc "`%{iframe: element, parent: document}` of a frame's document."
  def frame_of(doc), do: Map.get(st().meta, doc)

  @doc """
  Makes the document of a frame in the `<iframe>` element `iframe` out of the parsed tree `raw`.
  `keys` are what the process dictionary holds for it (see `@realm_keys`: its global scope, its
  `info`, ...). Returns the document's node id.
  """
  def new_realm(iframe, raw, url, keys, size \\ nil) do
    parent = node(iframe).doc
    doc = new_node(%{kind: :document})
    update_node_quiet(doc, &%{&1 | doc: doc})
    s = st()
    {w, h} = size || {s.width, s.height}

    fields = %{
      doc: doc,
      url: url,
      hist: [{url, :null}],
      hist_idx: 0,
      history_before: 0,
      scroll_restoration: "auto",
      width: w,
      height: h,
      scroll: {0.0, 0.0},
      content: {0.0, 0.0},
      rects: %{},
      current_script: nil,
      storage_origin: Browser.LocalStorage.origin(url),
      ce: %{},
      ce_done: MapSet.new(),
      write_after: nil
    }

    realms = Map.put(s.realms, doc, %{fields: fields, keys: keys})
    meta = Map.merge(Map.get(s, :meta, %{}), %{doc => %{iframe: iframe, parent: parent}})
    meta = Map.put_new(meta, s.main, %{iframe: nil, parent: nil})

    put_st(Map.merge(s, %{realms: realms, meta: meta, frames: Map.put(s.frames, iframe, doc)}))

    in_realm(doc, fn ->
      kids = Enum.map(raw, &build(&1, doc))
      update_node_quiet(doc, &%{&1 | kids: kids})
    end)

    doc
  end

  @doc "Takes a frame's document away: its nodes, its realm, the frames inside it."
  def destroy_realm(doc) do
    s = st()
    inner = for {d, %{parent: ^doc}} <- s.meta, do: d
    Enum.each(inner, &destroy_realm/1)
    s = st()
    ids = for {id, n} <- s.nodes, n.doc == doc, do: id
    iframe = s.meta |> Map.get(doc, %{}) |> Map.get(:iframe)
    frames = if iframe, do: Map.delete(s.frames, iframe), else: s.frames
    drop = MapSet.new(ids)

    listeners =
      s.listeners
      |> Map.drop([{:window, doc} | ids])

    realms = if s.doc == doc, do: s.realms, else: Map.delete(s.realms, doc)
    if s.doc == doc, do: Process.put(:dom_dead, doc)

    put_st(%{
      s
      | nodes: Map.drop(s.nodes, ids),
        wrappers: Map.drop(s.wrappers, ids ++ [{:aux, {:window, doc}}, {:aux, {:location, doc}}]),
        listeners: listeners,
        realms: realms,
        frames: frames,
        meta: Map.delete(s.meta, doc),
        fdirty: MapSet.delete(s.fdirty, doc),
        rev: s.rev + 1
    })

    _ = drop
    :ok
  end

  # what the host object `data` belongs to: the realm to run in, and the data as that realm
  # knows it (`:window` stands for the window of the running realm)
  defp split_realm({:window, d}), do: {d, :window}
  defp split_realm({:location, d}), do: {d, :location}
  defp split_realm({:history, d}), do: {d, :history}
  defp split_realm({:storage, area, d}), do: {d, {:storage, area}}
  defp split_realm(k) when k in [:window, :location, :history], do: {st().main, k}
  defp split_realm({:storage, _} = data), do: {st().main, data}

  defp split_realm(nid) when is_integer(nid) do
    case st().nodes do
      %{^nid => n} -> {n.doc, nid}
      _ -> {nil, nid}
    end
  end

  defp split_realm({k, nid} = data)
       when k in [:classlist, :style, :dataset] and is_integer(nid) do
    case st().nodes do
      %{^nid => n} -> {n.doc, data}
      _ -> {nil, data}
    end
  end

  defp split_realm(data), do: {nil, data}

  # runs `fun` in the realm of `this` (a host object of a document of a frame)
  defp maybe_realm(this, fun) do
    if map_size(st().realms) == 0 do
      fun.()
    else
      case this do
        {:obj, id} ->
          case deref(id) do
            %{class: :host, host: {__MODULE__, data}} -> in_realm(elem(split_realm(data), 0), fun)
            _ -> fun.()
          end

        _ ->
          fun.()
      end
    end
  end

  # the host object of this realm's window, location and history
  defp win_data, do: if(st().doc == st().main, do: :window, else: {:window, st().doc})
  defp win_host, do: aux_host(win_data(), :window)
  defp loc_host, do: aux_host(loc_data(), :location)
  defp hist_host, do: aux_host(hist_data(), :history)
  defp loc_data, do: if(st().doc == st().main, do: :location, else: {:location, st().doc})
  defp hist_data, do: if(st().doc == st().main, do: :history, else: {:history, st().doc})

  defp storage_host(area),
    do:
      aux_host(
        if(st().doc == st().main, do: {:storage, area}, else: {:storage, area, st().doc}),
        :storage
      )

  # the key window listeners are kept under
  defp win_key, do: if(st().doc == st().main, do: :window, else: {:window, st().doc})

  # a node's window: the one of the document it is in
  defp window_key_of(nid) do
    case root_of(nid) do
      root ->
        d = node(root).doc
        if d == st().main, do: :window, else: {:window, d}
    end
  end

  defp root_of(nid) do
    case node(nid).parent do
      nil -> nid
      p -> root_of(p)
    end
  end

  defp realm_key_to_doc(:window), do: st().main
  defp realm_key_to_doc({:window, d}), do: d
  defp realm_key_to_doc(nid) when is_integer(nid), do: node(nid).doc

  @doc "The queued side effects, oldest first; empties the queue."
  def take_outbox do
    s = st()
    put_st(%{s | outbox: []})
    Enum.reverse(s.outbox)
  end

  # what a script did that the session should hear of; a frame's does not reach it (what a
  # frame takes in as its address is done by `navigate_to/2`)
  defp out(item) do
    if st().doc == st().main, do: put_st(%{st() | outbox: [item | st().outbox]}), else: :ok
  end

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
      rev: 0,
      next: 1,
      wrappers: %{},
      listeners: %{},
      dirty: false,
      outbox: [],
      url: info.url,
      width: info[:width] || 960,
      height: info[:height] || 658,
      doc: nil,
      # the page's own document (`doc` is the one of the realm that is running: see `in_realm/2`)
      main: nil,
      # the other realms, by document: what `in_realm/2` swapped out; and the documents of
      # frames, by the `<iframe>` element
      realms: %{},
      frames: %{},
      meta: %{},
      # frame documents a script changed since the last `clean/0`
      fdirty: MapSet.new(),
      # the session history entries of this document, `{url, state}`: `pushState`, `replaceState`
      # and fragment navigations edit them, `history.back()` between them stays in the document
      hist: [{info.url, :null}],
      hist_idx: 0,
      history_before: info[:history_before] || 0,
      scroll_restoration: "auto",
      session: %{},
      storage_origin: Browser.LocalStorage.origin(info.url),
      usp: 0,
      ce: %{},
      ce_done: MapSet.new(),
      # where the layout put the elements (`Browser.Nids.rects/2`), the window's scroll
      # position, and the size of the page
      rects: %{},
      current_script: nil,
      write_after: nil,
      # editing: `designMode`, the focused editing host (a node id) and the selection the page
      # last reported (`report_selection/1`)
      design_mode: false,
      focus_ed: nil,
      ed_sel: nil,
      scroll: {0.0, 0.0},
      content: {0.0, 0.0},
      next_nid: Browser.Nids.max_nid(raw, -1) + 1
    })

    doc = new_node(%{kind: :document})
    s = st()
    put_st(%{s | doc: doc, main: doc})
    kids = Enum.map(raw, &build(&1, doc))
    update_node_quiet(doc, &%{&1 | kids: kids, doc: doc})
    clean()
    doc
  end

  defp update_node_quiet(nid, fun) do
    s = st()
    put_st(%{s | nodes: Map.put(s.nodes, nid, fun.(node(nid))), rev: s.rev + 1})
  end

  defp build({:text, t}, parent), do: new_node(%{kind: :text, text: t, parent: parent})

  defp build({:element, tag, attrs, kids}, parent) do
    {internal, visible} = Enum.split_with(attrs, fn {k, _} -> String.starts_with?(k, "@") end)
    nid = new_node(%{tag: tag, attrs: visible, internal: internal, parent: parent})
    kid_ids = Enum.map(kids, &build(&1, nid))

    if tag == "template" do
      # what is inside a template is its content: a fragment of its own, not part of the page
      frag = new_node(%{kind: :fragment})
      for k <- kid_ids, do: update_node_quiet(k, &%{&1 | parent: frag})
      update_node_quiet(frag, &%{&1 | kids: kid_ids})
      update_node_quiet(nid, &%{&1 | content: frag})
    else
      update_node_quiet(nid, &%{&1 | kids: kid_ids})
    end

    nid
  end

  # the fragment that holds a template's content (made when a script created the template)
  defp template_content(nid) do
    case node(nid).content do
      nil ->
        frag = new_node(%{kind: :fragment})
        update_node_quiet(nid, &%{&1 | content: frag})
        frag

      frag ->
        frag
    end
  end

  # the node whose kids `innerHTML` reads and writes
  defp inner_holder(%{tag: "template", kind: :element} = n), do: template_content(n.id)
  defp inner_holder(n), do: n.id

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

  # `host` is the layout number of the editing host the node is in, or nil: text and line breaks
  # in a host are exported with numbers of their own, so the layout can say where each one is
  defp export(nid, host \\ nil) do
    n = node(nid)

    case n.kind do
      :text ->
        {:text, n.text}

      :comment ->
        {:text, ""}

      _ ->
        inner = ed_host_for(n, host)
        attrs = export_attrs(n) ++ [{"@nid", ensure_nid(nid)}]

        attrs =
          if inner != nil and edit_attr(n) == true, do: attrs ++ [{"@edhost", 1}], else: attrs

        {:element, n.tag, attrs, export_kids(n, inner)}
    end
  end

  # the host the children of `n` are in: `n` itself when it makes them editable, else the host
  # `n` is in, unless `contenteditable=false` ends it
  defp ed_host_for(n, host) do
    cond do
      n.kind != :element -> host
      edit_attr(n) == true -> host || ensure_nid(n.id)
      edit_attr(n) == false -> nil
      host == nil and st().design_mode and n.tag == "body" -> ensure_nid(n.id)
      true -> host
    end
  end

  # numbers the text node or line break `nid` for the layout (`@znid` for the stand-in of a break)
  defp ed_text(nid, host) do
    n = node(nid)

    cond do
      n.kind == :text and n.text != "" ->
        [{:element, "@t", [{"@nid", ensure_nid(nid)}, {"@ed", host}], [{:text, n.text}]}]

      n.kind == :text ->
        []

      true ->
        []
    end
  end

  defp ed_break(nid, host) do
    n = node(nid)

    stand_in =
      case List.keyfind(n.internal, "@znid", 0) do
        {_, v} ->
          v

        nil ->
          v = st().next_nid
          put_st(%{st() | next_nid: v + 1})
          update_node_quiet(nid, &%{&1 | internal: &1.internal ++ [{"@znid", v}]})
          v
      end

    {:element, "@t", [{"@nid", stand_in}, {"@ed", host}, {"@z", ensure_nid(nid)}],
     [{:text, "\u200B"}]}
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

  defp export_kids(%{tag: "textarea", props: %{"value" => v}}, _host) when is_binary(v),
    do: [{:text, v}]

  defp export_kids(%{tag: "select"} = n, _host) do
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

  defp export_kids(n, nil), do: Enum.map(n.kids, &export/1)

  defp export_kids(n, host) do
    Enum.flat_map(n.kids, fn k ->
      case node(k) do
        %{kind: :text} -> ed_text(k, host)
        %{kind: :element, tag: "br"} -> [ed_break(k, host), export(k, host)]
        _ -> [export(k, host)]
      end
    end)
  end

  # ── text positions (JavaScript strings here count code points) ──

  defp cp_len(text), do: text |> String.to_charlist() |> length()

  defp cp_split(text, at) do
    {l, r} = text |> String.to_charlist() |> Enum.split(max(at, 0))
    {List.to_string(l), List.to_string(r)}
  end

  defp offset_arg(v) do
    case to_num_or_zero(v) do
      n when is_number(n) and n >= 0 -> trunc(n)
      _ -> 0
    end
  end

  defp char_data(nid) do
    n = node(nid)

    if n.kind not in [:text, :comment],
      do: throw_error("TypeError", "Not a CharacterData node.")

    n
  end

  # `(offset, count)` arguments clamped to the node's text
  defp data_range(n, args) do
    len = cp_len(n.text)
    from = offset_arg(arg(args, 0))

    if from > len,
      do:
        throw_error(
          "IndexSizeError",
          "The offset #{from} is larger than the node's length (#{len})."
        )

    {from, min(offset_arg(arg(args, 1)), len - from)}
  end

  # merges neighbouring text nodes below `nid` and drops empty ones
  defp normalize(nid) do
    kids = node(nid).kids
    for k <- kids, node(k).kind == :element, do: normalize(k)

    kids
    |> Enum.chunk_by(&(node(&1).kind == :text))
    |> Enum.each(fn [first | rest] = run ->
      if node(first).kind == :text do
        text = Enum.map_join(run, &node(&1).text)

        if text == "" do
          Enum.each(run, &detach/1)
        else
          update_node(first, &%{&1 | text: text})
          Enum.each(rest, &detach/1)
        end
      end
    end)
  end

  # what `a.compareDocumentPosition(b)` says: 2 b precedes, 4 b follows, +8 b contains a, +16 b is
  # inside a
  defp compare_position(a, b) do
    pa = Enum.reverse([a | ancestors(a)])
    pb = Enum.reverse([b | ancestors(b)])

    cond do
      a == b -> 0
      hd(pa) != hd(pb) -> 1 + 32 + 4
      b in ancestors(a) -> 8 + 2
      a in ancestors(b) -> 16 + 4
      true -> if branch_before?(pa, pb), do: 4, else: 2
    end
  end

  defp branch_before?([x | ra], [x | rb]), do: branch_before?(ra, rb)

  defp branch_before?([x | _], [y | _]) do
    kids = node(node(x).parent).kids
    Enum.find_index(kids, &(&1 == x)) < Enum.find_index(kids, &(&1 == y))
  end

  @block_tags ~w(address article aside blockquote body dd details div dl dt fieldset figcaption figure
                 footer form h1 h2 h3 h4 h5 h6 header hr html li main nav ol p pre section table ul)

  # `innerText`: the rendered text, with line breaks where blocks and `<br>` put them (white
  # space collapsed unless the text is preformatted)
  defp inner_text(nid) do
    nid
    |> inner_parts(false)
    |> List.flatten()
    |> collapse_breaks([])
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim("\n")
  end

  defp inner_parts(nid, pre?) do
    n = node(nid)

    case n.kind do
      :text ->
        [if(pre?, do: n.text, else: Regex.replace(~r/[ \t\n\r\f]+/, n.text, " "))]

      :element when n.tag in ~w(script style template) ->
        []

      :element when n.tag == "br" ->
        ["\n"]

      :element ->
        pre? = pre? or n.tag in ~w(pre textarea)
        kids = Enum.map(n.kids, &inner_parts(&1, pre?))

        cond do
          n.tag in ~w(td th) -> [kids, "\t"]
          n.tag == "tr" -> [kids |> trim_tab(), {:break, 1}]
          n.tag in ~w(p) -> [{:break, 2}, kids, {:break, 2}]
          n.tag in @block_tags -> [{:break, 1}, kids, {:break, 1}]
          true -> kids
        end

      _ ->
        Enum.map(n.kids, &inner_parts(&1, pre?))
    end
  end

  defp trim_tab(kids) do
    case List.flatten(kids) do
      [] -> []
      flat -> if List.last(flat) == "\t", do: List.delete_at(flat, -1), else: flat
    end
  end

  # runs of required breaks become the longest of them; spaces at line ends and starts go
  defp collapse_breaks([], acc), do: acc

  defp collapse_breaks([{:break, n} | rest], acc) do
    {more, rest} = Enum.split_while(rest, &match?({:break, _}, &1))
    count = Enum.max([n | for({:break, m} <- more, do: m)])
    acc = trim_line_end(acc)
    # breaks at the very start are dropped; a `<br>` already put a newline there
    acc =
      cond do
        acc == [] -> acc
        true -> missing_breaks(acc, count) ++ acc
      end

    collapse_breaks(rest, acc)
  end

  defp collapse_breaks([text | rest], acc) when is_binary(text) do
    acc =
      case {acc, text} do
        {[], _} ->
          [String.trim_leading(text, " ")]

        {["\n" | _], _} ->
          [String.trim_leading(text, " ") | acc]

        {[prev | _], " " <> _} ->
          if String.ends_with?(prev, " "),
            do: [String.trim_leading(text, " ") | acc],
            else: [text | acc]

        _ ->
          [text | acc]
      end

    collapse_breaks(rest, acc)
  end

  defp trim_line_end([prev | rest]) when is_binary(prev) and prev != "\n",
    do: [String.trim_trailing(prev, " ") | rest]

  defp trim_line_end(acc), do: acc

  # the newlines to add so the text ends with `count` of them (a `<br>` counts as one)
  defp missing_breaks(acc, count) do
    have = acc |> Enum.take_while(&(&1 == "\n" or &1 == "")) |> Enum.count(&(&1 == "\n"))
    List.duplicate("\n", max(count - have, 0))
  end

  # ── contenteditable ────────────────────────────────────────

  # true, false or nil (not set) from the `contenteditable` attribute of an element
  defp edit_attr(n) do
    case get_attr(n, "contenteditable") do
      nil -> nil
      v -> String.downcase(v) in ["", "true", "plaintext-only"]
    end
  end

  # is the node editable: by its own attribute or the nearest ancestor that has one, or `designMode`
  defp editable?(nid) do
    Enum.reduce_while([nid | ancestors(nid)], st().design_mode, fn id, default ->
      n = node(id)

      case n.kind == :element && edit_attr(n) do
        v when is_boolean(v) -> {:halt, v}
        _ -> {:cont, default}
      end
    end)
  end

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

  @doc "True when the node is inside a `<template>` (its content is inert: no script in it runs)."
  def in_template?(nid) do
    Enum.any?(ancestors(nid), fn a -> node(a).kind == :element and node(a).tag == "template" end)
  end

  defp elements(nid), do: Enum.filter(descendants(nid), &(node(&1).kind == :element))

  # the first element below `nid` in document order that `pred` accepts, without building the
  # list of every descendant
  defp find_element(nid, pred) do
    Enum.find_value(node(nid).kids, fn k ->
      n = node(k)

      cond do
        n.kind == :element and pred.(n) -> k
        true -> find_element(k, pred)
      end
    end)
  end

  defp element_by_id(doc, id), do: find_element(doc, &(get_attr(&1, "id") == id))

  @doc "The node id of the n-th `<form>` (the number the page's form index uses), or nil."
  def form_node(fid), do: Enum.at(Enum.filter(elements(st().doc), &(node(&1).tag == "form")), fid)

  # the number the page's form index uses for a `<form>`
  defp form_index(nid) do
    Enum.find_index(Enum.filter(elements(st().doc), &(node(&1).tag == "form")), &(&1 == nid))
  end

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
      frames_leaving(nid)
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

        adopt(child, node(parent).doc)
        connect(child)
    end
  end

  defp set_children(nid, kid_ids) do
    for k <- node(nid).kids do
      frames_leaving(k)
      update_node(k, &%{&1 | parent: nil})
    end

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

      if n.content != nil do
        content = clone(n.content, true)
        update_node_quiet(copy, &%{&1 | content: content})
      end
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
  def host_get(data, key, self) do
    if map_size(st().realms) == 0 do
      hget(data, key, self)
    else
      {doc, data} = split_realm(data)
      in_realm(doc, fn -> hget(data, key, self) end)
    end
  end

  defp hget(nid, key, self) when is_integer(nid) do
    n = node(nid)
    node_get(n, key, self)
  end

  defp hget({:classlist, nid}, key, _self), do: classlist_get(nid, key)
  defp hget({:style, nid}, key, _self), do: style_get(nid, key)
  defp hget({:dataset, nid}, key, _self), do: dataset_get(nid, key)
  defp hget(:window, key, _self), do: window_get(key)
  defp hget(:location, key, _self), do: location_get(key)
  defp hget({:usp, k}, key, _self), do: usp_get(k, key)
  defp hget({:storage, area}, key, _self), do: storage_get(area, key)

  defp hget(:history, "length", _self),
    do: {:ok, float(st().history_before + length(st().hist))}

  defp hget(:history, "state", _self), do: {:ok, hist_state()}
  defp hget(:history, "scrollRestoration", _self), do: {:ok, st().scroll_restoration}
  defp hget(_other, _key, _self), do: :miss

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
        {:ok, float(cp_len(n.text))}

      {"ownerDocument", _} ->
        {:ok, if(n.kind == :document, do: :null, else: wrap(n.doc))}

      {"isConnected", _} ->
        {:ok, connected?(n.id)}

      {"rows", :element} when n.tag in ["table", "thead", "tbody", "tfoot"] ->
        {:ok, nodes_array(table_rows(n))}

      {"tBodies", :element} when n.tag == "table" ->
        {:ok, nodes_array(for id <- element_kids(n.id), node(id).tag == "tbody", do: id)}

      {"tHead", :element} when n.tag == "table" ->
        {:ok, wrap_or_null(Enum.find(element_kids(n.id), &(node(&1).tag == "thead")))}

      {"tFoot", :element} when n.tag == "table" ->
        {:ok, wrap_or_null(Enum.find(element_kids(n.id), &(node(&1).tag == "tfoot")))}

      {"cells", :element} when n.tag == "tr" ->
        {:ok, nodes_array(row_cells(n.id))}

      {"cellIndex", :element} when n.tag in ["td", "th"] ->
        {:ok, float(position_in(n.id, row_cells(n.parent)))}

      {"rowIndex", :element} when n.tag == "tr" ->
        table =
          Enum.find(ancestors(n.id), &(node(&1).kind == :element and node(&1).tag == "table"))

        {:ok, float(if(table, do: position_in(n.id, table_rows(node(table))), else: -1))}

      {"sectionRowIndex", :element} when n.tag == "tr" ->
        {:ok,
         float(position_in(n.id, for(id <- element_kids(n.parent), node(id).tag == "tr", do: id)))}

      {_, :element} ->
        element_get(n, key, self)

      {_, :document} ->
        document_get(n, key)

      _ ->
        :miss
    end
  end

  # a table's rows in order: the head's, the bodies' (and rows of the table itself), the foot's
  defp table_rows(%{tag: "table", id: id}) do
    kids = element_kids(id)
    sections = fn tag -> for k <- kids, node(k).tag == tag, do: k end

    Enum.flat_map(sections.("thead"), &section_rows/1) ++
      Enum.flat_map(kids, fn k ->
        case node(k).tag do
          "tbody" -> section_rows(k)
          "tr" -> [k]
          _ -> []
        end
      end) ++ Enum.flat_map(sections.("tfoot"), &section_rows/1)
  end

  defp table_rows(%{id: id}), do: section_rows(id)

  defp section_rows(id), do: for(k <- element_kids(id), node(k).tag == "tr", do: k)

  defp row_cells(id), do: for(k <- element_kids(id), node(k).tag in ["td", "th"], do: k)

  defp position_in(id, ids), do: Enum.find_index(ids, &(&1 == id)) || -1

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
        {:ok, serialize_kids(inner_holder(n))}

      "outerHTML" ->
        {:ok, serialize(n.id)}

      "innerText" ->
        {:ok, inner_text(n.id)}

      "contentEditable" ->
        {:ok,
         case get_attr(n, "contenteditable") do
           nil -> "inherit"
           v -> if String.downcase(v) in ["", "true"], do: "true", else: String.downcase(v)
         end}

      "isContentEditable" ->
        {:ok, editable?(n.id)}

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
        attrs = Enum.map(n.attrs, fn {k, v} -> new_object([{"name", k}, {"value", v}]) end)
        list = new_array(attrs)
        # the list is a snapshot, but removing an attribute node through it empties it, so that
        # `while (el.attributes.length) el.removeAttributeNode(el.attributes[0])` ends
        for a <- attrs, do: put_hidden(a, "__list", list)
        {:ok, list}

      k when k in ~w(offsetWidth offsetHeight offsetTop offsetLeft clientWidth clientHeight
                     clientTop clientLeft scrollWidth scrollHeight scrollTop scrollLeft) ->
        {:ok, metric(n, k)}

      "tabIndex" ->
        {:ok, -1.0}

      k when k in @bool_attrs ->
        {:ok, get_attr(n, k) != nil}

      k when k in ~w(href src action) ->
        case get_attr(n, k) do
          nil -> {:ok, ""}
          v -> {:ok, resolve_url(String.trim(v))}
        end

      k
      when k in ~w(name placeholder title alt method target rel for lang dir role) ->
        {:ok, attr_or(n, k, "")}

      "htmlFor" ->
        {:ok, attr_or(n, "for", "")}

      "content" when n.tag == "template" ->
        {:ok, wrap(template_content(n.id))}

      "contentWindow" when n.tag == "iframe" ->
        {:ok, with(d when d != nil <- frame_doc_of(n.id), do: window_host_of(d)) || :null}

      "contentDocument" when n.tag == "iframe" ->
        {:ok, with(d when d != nil <- frame_doc_of(n.id), do: wrap(d)) || :null}

      "srcdoc" when n.tag == "iframe" ->
        {:ok, attr_or(n, "srcdoc", "")}

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

      "currentScript" ->
        {:ok, wrap_or_null(s.current_script)}

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
        {:ok, loc_host()}

      "defaultView" ->
        {:ok, win_host()}

      "readyState" ->
        {:ok, "complete"}

      "cookie" ->
        {:ok, Browser.Cookies.header(s.url, http: false) || ""}

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
        {:ok, wrap_or_null(ed_focused() || find_tag(s.doc, "body"))}

      "designMode" ->
        {:ok, if(s.design_mode, do: "on", else: "off")}

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
  def host_put(data, key, v, self) do
    if map_size(st().realms) == 0 do
      hput(data, key, v, self)
    else
      {doc, data} = split_realm(data)
      in_realm(doc, fn -> hput(data, key, v, self) end)
    end
  end

  defp hput(nid, key, v, _self) when is_integer(nid) do
    n = node(nid)
    node_put(n, key, v)
  end

  defp hput({:style, nid}, key, v, _), do: style_put(nid, key, v)
  defp hput({:dataset, nid}, key, v, _), do: dataset_put(nid, key, v)
  defp hput(:window, key, v, _), do: window_put(key, v)
  defp hput(:location, key, v, _), do: location_put(key, v)

  defp hput(:history, "scrollRestoration", v, _) do
    if to_str(v) in ["auto", "manual"], do: put_st(%{st() | scroll_restoration: to_str(v)})
    :ok
  end

  defp hput({:storage, area}, key, v, _), do: storage_put(area, key, v)
  defp hput(_other, _key, _v, _self), do: :miss

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

      {"on" <> event, :document} ->
        set_inline_handler(n.id, event, if(function?(v), do: v))
        :ok

      {"cookie", :document} ->
        Browser.Cookies.set_from_script(st().url, to_str(v))
        :ok

      {"designMode", :document} ->
        put_st(%{st() | design_mode: String.downcase(to_str(v)) == "on"})
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
        set_children(inner_holder(node(nid)), parse_fragment(to_str_or_empty(v)))
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
      when k in ~w(href src srcdoc name placeholder title alt action method target rel lang dir role type) ->
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
  defp target_obj({:window, _} = key), do: aux_host(key, :window)
  defp target_obj(nid), do: wrap(nid)

  @doc """
  Fires an event at `target` (a node id or `:window`): capture phase down from the window,
  the target, then bubbling back up. `init` is `%{prop => JS value}` for the event object plus
  `:bubbles`/`:cancelable`. Returns `:prevented` or `:ok`.
  """
  def dispatch(target, type, init \\ %{}) do
    # (`:window` is the window of the document that is running)
    target = if target == :window, do: win_key(), else: target
    in_realm(realm_key_to_doc(target), fn -> do_dispatch(target, type, init) end)
  end

  defp do_dispatch(target, type, init) do
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
          {"timeStamp", Browser.JS.Builtins.perf_now()}
        ] ++
          for({k, v} <- init, is_binary(k), do: {k, v}),
        proto({:dom, :event})
      )

    path =
      case target do
        :window -> [:window]
        {:window, _} -> [target]
        nid -> [nid | ancestors(nid)] ++ [window_key_of(nid)]
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
    if phase != :capture, do: run_inline_handler(target, type, event)

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

  # `<button onclick="go()">`: the attribute's code is a handler with `event` and `this`; the
  # handler of `<body onload>` and the like is the window's. Returning false cancels the event.
  @window_events ~w(load unload beforeunload resize scroll popstate hashchange message focus blur error
                    online offline storage pageshow pagehide languagechange)

  defp run_inline_handler(target, type, event) do
    holder =
      case target do
        :window when type in @window_events -> find_tag(st().main, "body")
        {:window, d} when type in @window_events -> find_tag(d, "body")
        nid when is_integer(nid) -> nid
        _ -> nil
      end

    with nid when is_integer(nid) <- holder,
         code when is_binary(code) <- get_attr(node(nid), "on" <> type),
         f when is_tuple(f) <- inline_function(nid, type, code) do
      try do
        if call(f, target_obj(target), [event]) == false and
             truthy(Interp.get(event, "cancelable")),
           do: Interp.put(event, "defaultPrevented", true)
      catch
        {:js_error, v} -> console_error("Uncaught " <> describe(v))
      end
    end

    :ok
  end

  defp inline_function(nid, type, code) do
    key = {:inline_handler, nid, type, code}

    case Process.get(key) do
      nil ->
        f =
          try do
            case Interp.lookup_scoped(global(), "Function") do
              {:ok, ctor} -> construct(ctor, ["event", code], ctor)
              _ -> :none
            end
          catch
            {:js_error, v} ->
              console_error("Uncaught " <> describe(v))
              :none

            {:syntax, msg} ->
              console_error("SyntaxError: " <> msg)
              :none
          end

        Process.put(key, f)
        f

      f ->
        f
    end
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

  defp serialize_kids(nid) do
    n = node(nid)
    holder = if n.kind == :element and n.tag == "template", do: template_content(nid), else: nid
    node(holder).kids |> Enum.map_join(&serialize/1)
  end

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

  @doc """
  Is a page at `url` a secure context? (https://w3c.github.io/webappsec-secure-contexts/) Its
  origin has to be potentially trustworthy: a secure scheme (https, wss), a file, `data:` or
  `about:blank` address, or a loopback host (`localhost`, `*.localhost`, 127.0.0.0/8, `::1`).
  Plain http to anywhere else is not.
  """
  def secure_context?(url) do
    uri = URI.parse(url || "")

    case uri.scheme do
      s when s in ["https", "wss", "file", "data", "about"] -> true
      s when s in ["http", "ws"] -> loopback?(uri.host)
      _ -> false
    end
  end

  defp loopback?(nil), do: false

  defp loopback?(host) do
    host = String.downcase(host)

    host == "localhost" or String.ends_with?(host, ".localhost") or host == "::1" or
      match?({:ok, {127, _, _, _}}, :inet.parse_ipv4_address(String.to_charlist(host))) or
      match?({:ok, {0, 0, 0, 0, 0, 0, 0, 1}}, :inet.parse_ipv6_address(String.to_charlist(host)))
  end

  defp window_get(key) do
    s = st()

    case key do
      k when k in ["window", "self", "globalThis", "frames"] ->
        {:ok, win_host()}

      "top" ->
        {:ok, aux_host(:window, :window)}

      "parent" ->
        case Map.get(s.meta, s.doc) do
          %{parent: p} when p != nil ->
            {:ok, aux_host(if(p == s.main, do: :window, else: {:window, p}), :window)}

          _ ->
            {:ok, win_host()}
        end

      "frameElement" ->
        case Map.get(s.meta, s.doc) do
          %{iframe: i} when i != nil -> {:ok, wrap(i)}
          _ -> {:ok, :null}
        end

      "length" ->
        {:ok, float(length(child_frames(s.doc)))}

      "document" ->
        {:ok, wrap(s.doc)}

      "on" <> event when event in @window_events ->
        {:ok, window_handler(event)}

      "location" ->
        {:ok, loc_host()}

      "history" ->
        {:ok, hist_host()}

      "innerWidth" ->
        {:ok, float(s.width)}

      "innerHeight" ->
        {:ok, float(s.height)}

      "outerWidth" ->
        {:ok, float(s.width)}

      "outerHeight" ->
        {:ok, float(s.height)}

      "isSecureContext" ->
        {:ok, secure_context?(s.url)}

      "devicePixelRatio" ->
        {:ok, 1.0}

      k when k in ["scrollX", "pageXOffset"] ->
        {:ok, elem(s.scroll, 0)}

      k when k in ["scrollY", "pageYOffset"] ->
        {:ok, elem(s.scroll, 1)}

      "localStorage" ->
        {:ok, storage_host(:local)}

      "sessionStorage" ->
        {:ok, storage_host(:session)}

      "navigator" ->
        {:ok, Process.get(:dom_navigator, :undefined)}

      _ ->
        # a global variable: `window.foo` is `foo`
        case Map.fetch(deref(global()).vars, key) do
          {:ok, v} ->
            {:ok, v}

          :error ->
            case frame_by_index(key) do
              {:ok, _} = frame ->
                frame

              :error ->
                case named_element(key) do
                  {:ok, _} = found -> found
                  :error -> :miss
                end
            end
        end
    end
  end

  # the documents of the frames in the document `doc`, oldest element first
  defp child_frames(doc) do
    for({d, %{parent: ^doc, iframe: i}} <- st().meta, is_integer(i), do: {i, d})
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  # `window[0]`: the window of a frame
  defp frame_by_index(key) do
    with {i, ""} <- Integer.parse(key),
         d when d != nil <- Enum.at(child_frames(st().doc), i) do
      {:ok, aux_host(if(d == st().main, do: :window, else: {:window, d}), :window)}
    else
      _ -> :error
    end
  end

  @doc """
  Named access on the window: an element with that `id` is a global (`<div id=log>` is `log`),
  after every real global. `:error` when there is no such element or no document.
  """
  def named_element(name) when is_binary(name) do
    with %{doc: doc} <- st(),
         nid when not is_nil(nid) <- named_nid(doc, name) do
      {:ok, wrap(nid)}
    else
      _ -> :error
    end
  end

  def named_element(_), do: :error

  # Scripts (and the runtime's own shims) probe undeclared globals (`typeof Foo`, `window.Foo`)
  # over and over: one pass over the tree makes an index of the ids, kept until the tree changes.
  defp named_nid(doc, name) do
    rev = st().rev

    index =
      case Process.get(:dom_ids) do
        {^rev, ^doc, m} ->
          m

        _ ->
          m = collect_ids(doc, %{})
          Process.put(:dom_ids, {rev, doc, m})
          m
      end

    Map.get(index, name)
  end

  # id => the first element (in document order) with it
  defp collect_ids(nid, acc) do
    Enum.reduce(node(nid).kids, acc, fn k, acc ->
      n = node(k)

      acc =
        case n.kind == :element and get_attr(n, "id") do
          id when is_binary(id) -> Map.put_new(acc, id, k)
          _ -> acc
        end

      collect_ids(k, acc)
    end)
  end

  defp window_put(key, v) do
    case key do
      "location" ->
        location_put("href", v)

      "on" <> event when event in @window_events ->
        set_inline_handler(win_key(), event, if(function?(v), do: v))
        :ok

      _ ->
        declare(global(), key, v)
        :ok
    end
  end

  # `window.onload` and the like: the function assigned, or null
  defp window_handler(event) do
    case Enum.find(Map.get(st().listeners, win_key(), []), &(&1.type == event and &1[:inline])) do
      nil -> :null
      l -> l.fun
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

      "ancestorOrigins" ->
        {:ok, new_array([])}

      _ ->
        :miss
    end
  end

  defp host_with_port(uri) do
    if uri.port && uri.port != URI.default_port(uri.scheme),
      do: "#{uri.host}:#{uri.port}",
      else: uri.host || ""
  end

  defp location_put("href", v), do: navigate_to(resolve_url(to_str(v)))

  defp location_put("search", v),
    do: location_update(&%{&1 | query: nilify(String.trim_leading(to_str(v), "?"))})

  defp location_put("hash", v),
    do: location_update(&%{&1 | fragment: String.trim_leading(to_str(v), "#")})

  defp location_put("pathname", v) do
    path = to_str(v)

    location_update(
      &%{&1 | path: if(String.starts_with?(path, "/"), do: path, else: "/" <> path)}
    )
  end

  defp location_put("protocol", v) do
    scheme = v |> to_str() |> String.trim_trailing(":") |> String.downcase()

    if scheme in ["http", "https"] do
      location_update(fn uri ->
        port =
          if uri.port == URI.default_port(uri.scheme),
            do: URI.default_port(scheme),
            else: uri.port

        %{uri | scheme: scheme, port: port}
      end)
    else
      :ok
    end
  end

  defp location_put("host", v) do
    case String.split(to_str(v), ":", parts: 2) do
      [host, port] -> location_update(&%{&1 | host: host, port: parse_port(port, &1)})
      [host] -> location_update(&%{&1 | host: host, port: URI.default_port(&1.scheme)})
    end
  end

  defp location_put("hostname", v), do: location_update(&%{&1 | host: to_str(v)})

  defp location_put("port", v) do
    case to_str(v) do
      "" -> location_update(&%{&1 | port: URI.default_port(&1.scheme)})
      port -> location_update(&%{&1 | port: parse_port(port, &1)})
    end
  end

  defp location_put(_, _), do: :miss

  defp parse_port(text, uri) do
    case Integer.parse(text) do
      {n, _} when n in 0..65535 -> n
      _ -> uri.port
    end
  end

  defp nilify(""), do: nil
  defp nilify(s), do: s

  # navigates to the current address with one part changed
  defp location_update(fun) do
    uri = URI.parse(st().url)

    if uri.scheme in ["http", "https", "file"],
      do: navigate_to(uri |> fun.() |> URI.to_string()),
      else: :ok

    :ok
  end

  # Where `location.href = ...`, `assign` and `replace` go. An address that differs from this
  # page's only in its fragment stays in the document: a new history entry (or the current one,
  # for `replace`), `popstate` and `hashchange`, and the page scrolls to the fragment.
  defp navigate_to(url, mode \\ :push) do
    {target, fragment} = Browser.Fetch.split_fragment(url)
    {here, _} = Browser.Fetch.split_fragment(st().url)

    cond do
      # the same address again, or only another fragment: the document stays
      fragment != nil and target == here and url == st().url -> :ok
      fragment != nil and target == here -> hash_navigation(url, mode)
      st().doc != st().main -> navigate_frame(url)
      true -> out({:navigate, url, mode})
    end

    :ok
  end

  # a frame goes to another page: its element loads it
  defp navigate_frame(url) do
    iframe = st().meta |> Map.get(st().doc, %{}) |> Map.get(:iframe)

    if iframe do
      page = node(iframe).doc
      source = {:url, url}
      tok = make_ref()
      Process.put({:dom_frame_tok, iframe}, tok)

      fire = fn _this, _ ->
        with true <- Process.get({:dom_frame_tok, iframe}) == tok,
             hook when is_function(hook) <- Process.get(:rt_load_frame) do
          hook.(iframe, source, page)
        end

        :undefined
      end

      Browser.JS.Builtins.add_timer(native("", fire), 0.0)
    end

    :ok
  end

  defp hash_navigation(url, mode) do
    old = st().url
    if mode == :push, do: hist_push(url, :null), else: hist_replace(url, :null)
    out({:hash, url, mode})
    fire_popstate(:null)
    fire_hashchange(old, url)
  end

  @doc """
  The session followed a link to a fragment of this page: a new history entry, `popstate` and
  `hashchange`.
  """
  def fragment_navigation(url) do
    old = st().url

    if url != old do
      hist_push(url, :null)
      fire_popstate(:null)
      fire_hashchange(old, url)
    end

    :ok
  end

  @doc """
  `history.go(n)` between the entries this document made: `:moved` (and `popstate`, and
  `hashchange` if only the fragment differs) or `:out_of_range`, when going `n` entries
  leaves the document.
  """
  def traverse(n) do
    s = st()
    idx = s.hist_idx + n

    if idx >= 0 and idx < length(s.hist) do
      {url, state} = Enum.at(s.hist, idx)
      old = s.url
      put_st(%{s | hist_idx: idx, url: url})
      fire_popstate(state)
      if hash_only_change?(old, url), do: fire_hashchange(old, url)
      :moved
    else
      :out_of_range
    end
  end

  defp hash_only_change?(a, b) do
    a != b and
      elem(Browser.Fetch.split_fragment(a), 0) == elem(Browser.Fetch.split_fragment(b), 0)
  end

  defp fire_popstate(state) do
    dispatch(:window, "popstate", %{"state" => state, bubbles: false, cancelable: false})
  end

  defp fire_hashchange(old, new) do
    dispatch(:window, "hashchange", %{
      "oldURL" => old,
      "newURL" => new,
      bubbles: false,
      cancelable: false
    })
  end

  defp hist_state do
    {_, state} = Enum.at(st().hist, st().hist_idx)
    state
  end

  # a new entry after the current one (the ones that came after it are gone)
  defp hist_push(url, state) do
    s = st()
    hist = Enum.take(s.hist, s.hist_idx + 1) ++ [{url, state}]
    put_st(%{s | hist: hist, hist_idx: length(hist) - 1, url: url})
  end

  defp hist_replace(url, state) do
    s = st()
    put_st(%{s | hist: List.replace_at(s.hist, s.hist_idx, {url, state}), url: url})
  end

  defp resolve_url(href), do: Browser.Fetch.resolve(st().url, href)

  # ── Storage ────────────────────────────────────────────────

  # `localStorage` is shared by the pages of an origin and kept on disk
  # (`Browser.LocalStorage`); `sessionStorage` belongs to this page. A page whose address
  # has no origin (`about:`, `data:`) gets a `localStorage` that lasts as long as it does.
  defp storage_area(this) do
    case this do
      {:obj, id} ->
        case deref(id) do
          %{class: :host, host: {__MODULE__, {:storage, area}}} -> area
          _ -> throw_error("TypeError", "Illegal invocation")
        end

      _ ->
        throw_error("TypeError", "Illegal invocation")
    end
  end

  defp subscribe_storage do
    case st().storage_origin do
      nil -> :ok
      origin -> Browser.LocalStorage.subscribe(origin)
    end
  end

  defp storage_origin, do: st().storage_origin || {:page, self()}

  # items of a page without an origin: they last as long as the page
  defp page_items(origin), do: Process.get({:local_items, origin}, %{})

  defp storage_read(:session, key), do: Map.get(st().session, key)

  defp storage_read(:local, key) do
    case storage_origin() do
      origin when is_binary(origin) -> Browser.LocalStorage.get(origin, key)
      origin -> Map.get(page_items(origin), key)
    end
  end

  defp storage_length(:local) do
    case storage_origin() do
      origin when is_binary(origin) -> Browser.LocalStorage.count(origin)
      origin -> map_size(page_items(origin))
    end
  end

  defp storage_length(:session), do: map_size(st().session)

  defp storage_key(:local, index) do
    case storage_origin() do
      origin when is_binary(origin) -> Browser.LocalStorage.key(origin, index)
      origin -> page_items(origin) |> Map.keys() |> Enum.sort() |> Enum.at(index)
    end
  end

  defp storage_key(:session, index),
    do: st().session |> Map.keys() |> Enum.sort() |> Enum.at(index)

  defp storage_set(:session, key, value) do
    put_st(%{st() | session: Map.put(st().session, key, value)})
    :ok
  end

  defp storage_set(:local, key, value) do
    case storage_origin() do
      origin when is_binary(origin) ->
        case Browser.LocalStorage.put(origin, key, value) do
          :ok -> :ok
          {:error, :quota} -> throw_quota_error()
        end

      origin ->
        Process.put({:local_items, origin}, Map.put(page_items(origin), key, value))
        :ok
    end
  end

  defp throw_quota_error do
    err = make_error("Error", "The quota has been exceeded.")
    put(err, "name", "QuotaExceededError")
    put(err, "code", 22.0)
    throw({:js_error, err})
  end

  defp storage_remove(:session, key) do
    put_st(%{st() | session: Map.delete(st().session, key)})
    :ok
  end

  defp storage_remove(:local, key) do
    case storage_origin() do
      origin when is_binary(origin) -> Browser.LocalStorage.delete(origin, key)
      origin -> Process.put({:local_items, origin}, Map.delete(page_items(origin), key))
    end

    :ok
  end

  defp storage_clear(:session) do
    put_st(%{st() | session: %{}})
    :ok
  end

  defp storage_clear(:local) do
    case storage_origin() do
      origin when is_binary(origin) -> Browser.LocalStorage.clear(origin)
      origin -> Process.delete({:local_items, origin})
    end

    :ok
  end

  defp storage_get(area, key) do
    case key do
      "length" -> {:ok, float(storage_length(area))}
      k when k in ~w(getItem setItem removeItem clear key) -> :miss
      k -> {:ok, storage_read(area, k) || :undefined}
    end
  end

  defp storage_keys(:session), do: st().session |> Map.keys() |> Enum.sort()

  defp storage_keys(:local) do
    case storage_origin() do
      origin when is_binary(origin) -> Browser.LocalStorage.keys(origin)
      origin -> page_items(origin) |> Map.keys() |> Enum.sort()
    end
  end

  # `Object.keys(localStorage)` and `delete localStorage.name` see the items; every other host
  # object (nodes, `window`...) behaves like a plain object
  @doc false
  def host_keys({:storage, area}), do: storage_keys(area)
  def host_keys(_other), do: :default

  @doc false
  def host_delete({:storage, area}, key) when is_binary(key) do
    storage_remove(area, key)
    true
  end

  def host_delete(_other, _key), do: :default

  defp storage_put(area, key, v), do: storage_set(area, key, to_str(v))

  @doc "The address of the page, for the origin of its databases."
  def page_url, do: st().url

  @doc """
  Another page changed `localStorage`: fires `storage` on the window with what changed
  (`key` is nil for `clear`).
  """
  def storage_changed(key, old, new) do
    dispatch(:window, "storage", %{
      "key" => key || :null,
      "oldValue" => old || :null,
      "newValue" => new || :null,
      "url" => st().url,
      "storageArea" => aux_host({:storage, :local}, :storage),
      bubbles: false,
      cancelable: false
    })
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

  defp connected?(nid), do: node(root_of(nid)).kind == :document

  # an element that is in the document gets upgraded, or told it was connected again
  defp connect(nid) do
    frames_arriving(nid)

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

  # a node taken into another document (a script put one document's node in another's tree)
  defp adopt(nid, doc) do
    n = node(nid)

    if n.doc != doc do
      update_node_quiet(nid, &%{&1 | doc: doc})
      for k <- n.kids, do: adopt(k, doc)
      if n.content != nil, do: adopt(n.content, doc)
    end

    :ok
  end

  # ── frames ─────────────────────────────────────────────────

  # `<iframe>`s in the subtree that a script is putting into the document
  defp frames_arriving(nid) do
    if Process.get(:dom_has_iframe) && connected?(nid) do
      for e <- [nid | descendants(nid)], node(e).kind == :element, node(e).tag == "iframe" do
        load_frame(e)
      end
    end

    :ok
  end

  # the realms of the frames in a subtree that is leaving the document go with it
  defp frames_leaving(nid) do
    if Process.get(:dom_has_iframe) && st().frames != %{} do
      for e <- [nid | descendants(nid)],
          node(e).kind == :element,
          node(e).tag == "iframe" do
        cancel_frame_load(e)
        if d = Map.get(st().frames, e), do: destroy_realm(d)
      end
    end

    :ok
  end

  @doc "The `<iframe>`s of the page's document that have not been loaded yet get their load."
  def load_initial_frames do
    if Process.get(:dom_has_iframe) do
      for e <- elements(st().doc), node(e).tag == "iframe", not is_map_key(st().frames, e) do
        load_frame(e)
      end
    end

    :ok
  end

  # what an `<iframe>` shows: its `srcdoc`, the page at its `src`, or an empty page
  defp frame_source(n) do
    cond do
      (v = get_attr(n, "srcdoc")) != nil ->
        {:srcdoc, v}

      (v = get_attr(n, "src")) not in [nil, "", "about:blank"] ->
        {:url, resolve_url(String.trim(v))}

      true ->
        :blank
    end
  end

  defp cancel_frame_load(iframe), do: Process.put({:dom_frame_tok, iframe}, make_ref())

  # loads the frame in a task of its own (the runtime does it: `:rt_load_frame`)
  defp load_frame(iframe) do
    source = frame_source(node(iframe))
    tok = make_ref()
    Process.put({:dom_frame_tok, iframe}, tok)
    page = st().doc

    fire = fn _this, _ ->
      with true <- Process.get({:dom_frame_tok, iframe}) == tok,
           hook when is_function(hook) <- Process.get(:rt_load_frame) do
        hook.(iframe, source, page)
      end

      :undefined
    end

    Browser.JS.Builtins.add_timer(native("", fire), 0.0)
  end

  # `contentWindow` and `contentDocument` of a frame that is in a document: until it has loaded
  # something, an empty page
  defp frame_doc_of(nid) do
    case Map.get(st().frames, nid) do
      nil ->
        with true <- connected?(nid),
             hook when is_function(hook) <- Process.get(:rt_blank_frame),
             d when is_integer(d) <- hook.(nid) do
          d
        else
          _ -> nil
        end

      d ->
        d
    end
  end

  defp window_host_of(d),
    do: aux_host(if(d == st().main, do: :window, else: {:window, d}), :window)

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

    image_src_changed(nid, name, new)

    if name in ["src", "srcdoc"] and node(nid).tag == "iframe" and
         (old != new or name == "srcdoc") and connected?(nid) do
      if d = Map.get(st().frames, nid), do: destroy_realm(d)
      load_frame(nid)
    end

    :ok
  end

  # An image with a `data:` URL is decoded at once, so its `load` or `error` event can come
  # right after the script that set the source (other URLs load with the page).
  defp image_src_changed(nid, "src", "data:" <> _ = url) do
    if node(nid).tag == "img" do
      fire = fn _this, _ ->
        ok? =
          match?({:ok, bytes} when bytes != "", Browser.Images.decode_data_url(url)) and
            Browser.Images.sniff(elem(Browser.Images.decode_data_url(url), 1)) != :unknown

        dispatch(nid, if(ok?, do: "load", else: "error"), %{bubbles: false, cancelable: false})
        :undefined
      end

      Browser.JS.Builtins.add_timer(native("", fire), 0.0)
    end

    :ok
  end

  defp image_src_changed(_nid, _name, _value), do: :ok

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

  # ── editing: focus, the selection report, the hooks the editing prelude calls ──

  @doc """
  The selection as the page last reported it: `nil` when there is none, else `%{anchor: {nid,
  offset}, focus: {nid, offset}, host: nid}` with the numbers the layout knows the nodes by
  (`Browser.Nids`) and offsets in characters of a text node.
  """
  def ed_sel, do: st().ed_sel

  @doc "True when the document has an editing host or is in `designMode`."
  def has_editable? do
    st().design_mode or
      Enum.any?(st().nodes, fn {_, n} -> n.kind == :element and edit_attr(n) == true end)
  end

  @doc "The editing host (a layout number) that has focus, or nil."
  def ed_focus_nid do
    case ed_focused() do
      nil -> nil
      nid -> ensure_nid(nid)
    end
  end

  # the focused host, if it is still in the document
  defp ed_focused do
    case st().focus_ed do
      nil -> nil
      nid -> if Map.has_key?(st().nodes, nid) and connected?(nid), do: nid
    end
  end

  # an element that makes its contents editable: `contenteditable` itself, not inherited
  defp ed_host?(nid) do
    n = node(nid)
    n.kind == :element and edit_attr(n) == true
  end

  defp focus_element(nid) do
    cond do
      st().focus_ed == nid ->
        :ok

      ed_host?(nid) ->
        blur_focused()
        put_st(%{st() | focus_ed: nid})
        out({:focus_edit, ensure_nid(nid)})
        dispatch(nid, "focus", %{bubbles: false, cancelable: false})
        dispatch(nid, "focusin", %{bubbles: true, cancelable: false})
        :ok

      true ->
        :ok
    end
  end

  defp blur_focused do
    case st().focus_ed do
      nil ->
        :ok

      nid ->
        put_st(%{st() | focus_ed: nil})
        if Map.has_key?(st().nodes, nid), do: blur_events(nid)
        :ok
    end
  end

  defp blur_events(nid) do
    dispatch(nid, "blur", %{bubbles: false, cancelable: false})
    dispatch(nid, "focusout", %{bubbles: true, cancelable: false})
  end

  @doc "The session focused the editing host numbered `layout_nid` (a click, Tab or autofocus)."
  def ed_focus(layout_nid) do
    case nid_numbered(layout_nid) do
      nil -> :ok
      nid -> focus_element(nid)
    end
  end

  @doc "The session took focus away from the editing host (a click elsewhere, Tab, Escape)."
  def ed_blur do
    case st().focus_ed do
      nil ->
        :ok

      nid ->
        put_st(%{st() | focus_ed: nil})
        if Map.has_key?(st().nodes, nid), do: blur_events(nid)
        :ok
    end
  end

  @doc "Focuses the first editing host with `autofocus`, once the page has loaded."
  def autofocus do
    case Enum.find(elements(st().doc), fn id ->
           n = node(id)
           ed_host?(id) and get_attr(n, "autofocus") != nil
         end) do
      nil -> :ok
      nid -> focus_element(nid)
    end
  end

  @doc "The node (element or text) the layout numbers `n`, or nil."
  def node_numbered(n), do: nid_numbered(n)

  @doc """
  The pointer moved from the element the layout numbers `old` to the one it numbers `new` (nil:
  none): `mouseout` and `mouseover` (which bubble, and are what frameworks listen to), and
  `mouseleave` / `mouseenter` for each element the pointer left or came into.
  """
  def hover(old, new) do
    {old_n, new_n} = {old && nid_numbered(old), new && nid_numbered(new)}
    chain = fn n -> if n, do: [n | ancestors(n)], else: [] end
    {old_chain, new_chain} = {chain.(old_n), chain.(new_n)}
    related = fn n -> %{"relatedTarget" => wrap_or_null(n)} end
    quiet = %{bubbles: false, cancelable: false}

    if old_n, do: dispatch(old_n, "mouseout", related.(new_n))

    for n <- old_chain,
        n not in new_chain,
        do: dispatch(n, "mouseleave", Map.merge(quiet, related.(new_n)))

    if new_n, do: dispatch(new_n, "mouseover", related.(old_n))

    for n <- Enum.reverse(new_chain),
        n not in old_chain,
        do: dispatch(n, "mouseenter", Map.merge(quiet, related.(old_n)))

    :ok
  end

  # the node (element or text) the layout numbers `n`
  defp nid_numbered(n) do
    Enum.find_value(st().nodes, fn {id, node} ->
      if List.keyfind(node.internal, "@nid", 0) == {"@nid", n}, do: id
    end)
  end

  @doc """
  Runs the editing prelude's `__ed_action(name, args...)`: what the session does for the user's
  keys and clicks in an editing host (typing, deleting, moving the caret, placing it).
  """
  def ed_call(name, args) do
    case Interp.get(deref_global("__ed"), "action") do
      :undefined ->
        :ok

      f ->
        call(f, :undefined, [name | Enum.map(args, &if(is_integer(&1), do: &1 * 1.0, else: &1))])
    end
  end

  defp ed_object do
    new_object([
      {"nid", native("nid", fn _this, args -> float(ensure_nid(nid_of(arg(args, 0)))) end)},
      {"node",
       native("node", fn _this, args ->
         case nid_numbered(offset_arg(arg(args, 0))) do
           nil -> :null
           nid -> wrap(nid)
         end
       end)},
      {"report",
       native("report", fn _this, args ->
         sel =
           case args do
             [a, ao, f, fo, host] when is_tuple(a) ->
               %{
                 anchor: {ensure_nid(nid_of(a)), offset_arg(ao)},
                 focus: {ensure_nid(nid_of(f)), offset_arg(fo)},
                 host: ensure_nid(nid_of(host))
               }

             _ ->
               nil
           end

         put_st(%{st() | ed_sel: sel})
         :undefined
       end)},
      {"focused",
       native("focused", fn _this, _ ->
         case ed_focused() do
           nil -> :null
           nid -> wrap(nid)
         end
       end)},
      {"focus",
       native("focus", fn _this, args ->
         focus_element(nid_of(arg(args, 0)))
         :undefined
       end)},
      {"isHost", native("isHost", fn _this, args -> ed_host?(nid_of(arg(args, 0))) end)},
      {"editable", native("editable", fn _this, args -> editable?(nid_of(arg(args, 0))) end)},
      {"clipboard",
       native("clipboard", fn _this, args ->
         out({:clipboard, to_str(arg(args, 0))})
         :undefined
       end)},
      {"designMode", native("designMode", fn _this, _ -> st().design_mode end)}
    ])
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
    Interp.declare(scope, "__ed", ed_object())
    :ok
  end

  # (a method called on a node of a frame's document runs as that document's script would)
  defp def_fn(obj, name, fun),
    do:
      put_hidden(
        obj,
        name,
        native(name, fn this, args -> maybe_realm(this, fn -> fun.(this, args) end) end)
      )

  # -- canvas 2D ------------------------------------------------------------------

  # `canvas.getContext("2d")`: one context per canvas, drawing into `Browser.Canvas`
  # (rectangles only). Other kinds of context are not there: null, as the standard says.
  defp canvas_context(this, "2d") do
    nid = this_nid(this)

    if node(nid).tag == "canvas" do
      case Process.get({:canvas_ctx, nid}) do
        nil ->
          ctx =
            new_object(
              [
                {"fillStyle", "#000000"},
                {"strokeStyle", "#000000"},
                {"lineWidth", 1.0},
                {"globalAlpha", 1.0},
                {"canvas", this}
              ],
              Process.get(:canvas_ctx_proto)
            )

          Process.put({:canvas_ctx, nid}, ctx)
          ctx

        ctx ->
          ctx
      end
    else
      :null
    end
  end

  defp canvas_context(_this, _kind), do: :null

  # The surface of a canvas, made when first needed and again when the script changes the
  # canvas's size (which also clears it).
  defp canvas_surface(this) do
    nid = this_nid(this)

    if node(nid).tag == "canvas" do
      w = canvas_dim(this, nid, "width", 300)
      h = canvas_dim(this, nid, "height", 150)

      case Process.get({:canvas, nid}) do
        %Browser.Canvas{w: ^w, h: ^h} = surface -> surface
        _ -> Browser.Canvas.new(w, h)
      end
    end
  end

  defp canvas_dim(this, nid, name, default) do
    from_prop = Interp.get(this, name)

    n =
      cond do
        is_number(from_prop) -> from_prop
        v = get_attr(node(nid), name) -> to_num(v)
        true -> default
      end

    if is_number(n) and n >= 0, do: trunc(n), else: default
  end

  defp canvas_color(ctx, prop) do
    alpha = ctx |> Interp.get("globalAlpha") |> to_num_or_zero() |> min(1) |> max(0)

    case Browser.Color.parse_alpha(to_str(Interp.get(ctx, prop))) do
      {r, g, b, a} -> {r, g, b, round(a * alpha)}
      # unparsable colours leave the previous one, which is not tracked: black
      _ -> {0, 0, 0, round(255 * alpha)}
    end
  end

  defp canvas_draw(ctx, fun) do
    this = Interp.get(ctx, "canvas")

    with surface when surface != nil <- canvas_surface(this) do
      Process.put({:canvas, this_nid(this)}, fun.(surface))
    end

    :undefined
  end

  defp install_canvas_context(p) do
    def_fn(p, "fillRect", fn this, args ->
      [x, y, w, h] = for i <- 0..3, do: to_num_or_zero(arg(args, i))

      canvas_draw(
        this,
        &Browser.Canvas.fill_rect(&1, x, y, w, h, canvas_color(this, "fillStyle"))
      )
    end)

    def_fn(p, "strokeRect", fn this, args ->
      [x, y, w, h] = for i <- 0..3, do: to_num_or_zero(arg(args, i))
      lw = this |> Interp.get("lineWidth") |> to_num_or_zero()

      canvas_draw(
        this,
        &Browser.Canvas.stroke_rect(&1, x, y, w, h, lw, canvas_color(this, "strokeStyle"))
      )
    end)

    def_fn(p, "clearRect", fn this, args ->
      [x, y, w, h] = for i <- 0..3, do: to_num_or_zero(arg(args, i))
      canvas_draw(this, &Browser.Canvas.clear_rect(&1, x, y, w, h))
    end)
  end

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
      %{class: :host, host: {__MODULE__, {:window, _} = key}} -> key
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
    def_fn(p, "getRootNode", fn this, _ -> wrap(root_of(this_nid(this))) end)

    def_fn(p, "normalize", fn this, _ ->
      normalize(this_nid(this))
      :undefined
    end)

    def_fn(p, "splitText", fn this, args ->
      nid = this_nid(this)
      n = node(nid)
      len = cp_len(n.text)
      at = offset_arg(arg(args, 0))

      if n.kind != :text, do: throw_error("TypeError", "splitText: not a Text node")

      if at > len,
        do:
          throw_error(
            "IndexSizeError",
            "The offset #{at} is larger than the node's length (#{len})."
          )

      {left, right} = cp_split(n.text, at)
      fresh = new_node(%{kind: :text, text: right})
      update_node(nid, &%{&1 | text: left})

      if parent = n.parent, do: insert(parent, fresh, elem(siblings(nid), 1) |> List.first())
      wrap(fresh)
    end)

    def_fn(p, "compareDocumentPosition", fn this, args ->
      float(compare_position(this_nid(this), nid_of(arg(args, 0))))
    end)

    # CharacterData
    def_fn(p, "substringData", fn this, args ->
      n = char_data(this_nid(this))
      {from, count} = data_range(n, args)
      n.text |> cp_split(from) |> elem(1) |> cp_split(count) |> elem(0)
    end)

    def_fn(p, "appendData", fn this, args ->
      nid = this_nid(this)
      n = char_data(nid)
      update_node(nid, &%{&1 | text: n.text <> to_str(arg(args, 0))})
      :undefined
    end)

    def_fn(p, "insertData", fn this, args ->
      nid = this_nid(this)
      n = char_data(nid)
      at = offset_arg(arg(args, 0))

      if at > cp_len(n.text),
        do: throw_error("IndexSizeError", "The offset is larger than the node's length.")

      {l, r} = cp_split(n.text, at)
      update_node(nid, &%{&1 | text: l <> to_str(arg(args, 1)) <> r})
      :undefined
    end)

    def_fn(p, "deleteData", fn this, args ->
      nid = this_nid(this)
      n = char_data(nid)
      {from, count} = data_range(n, args)
      {l, rest} = cp_split(n.text, from)
      {_, r} = cp_split(rest, count)
      update_node(nid, &%{&1 | text: l <> r})
      :undefined
    end)

    def_fn(p, "replaceData", fn this, args ->
      nid = this_nid(this)
      n = char_data(nid)
      {from, count} = data_range(n, args)
      {l, rest} = cp_split(n.text, from)
      {_, r} = cp_split(rest, count)
      update_node(nid, &%{&1 | text: l <> to_str(arg(args, 2)) <> r})
      :undefined
    end)

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

    for name <- ~w(select showModal close pause load) do
      def_fn(p, name, fn _this, _ -> :undefined end)
    end

    # nothing is played, but a script that starts a video gets its promise
    def_fn(p, "play", fn _this, _ ->
      promise = Browser.JS.Promise.new()
      Browser.JS.Promise.fulfill(promise, :undefined)
      promise
    end)

    def_fn(p, "canPlayType", fn _this, _ -> "" end)

    def_fn(p, "getContext", fn this, args -> canvas_context(this, to_str(arg(args, 0))) end)

    def_fn(p, "toDataURL", fn this, _ ->
      case canvas_surface(this) do
        nil -> "data:,"
        surface -> Browser.Canvas.to_data_url(surface)
      end
    end)

    def_fn(p, "getAttributeNode", fn this, args ->
      name = String.downcase(to_str(arg(args, 0)))

      case get_attr(node(this_nid(this)), name) do
        nil -> :null
        v -> new_object([{"name", name}, {"value", v}, {"nodeName", name}, {"nodeValue", v}])
      end
    end)

    def_fn(p, "removeAttributeNode", fn this, args ->
      attr = arg(args, 0)
      remove_attr(this_nid(this), to_str(Interp.get(attr, "name")))

      with {:obj, _} = list <- Interp.get(attr, "__list"),
           {:obj, _} = splice <- Interp.get(list, "splice") do
        index = Enum.find_index(array_list(list), &(&1 == attr))
        if index, do: Interp.call(splice, list, [index * 1.0, 1.0])
      end

      attr
    end)

    def_fn(p, "setAttributeNode", fn this, args ->
      a = arg(args, 0)
      set_attr(this_nid(this), to_str(Interp.get(a, "name")), to_str(Interp.get(a, "value")))
      :null
    end)

    def_fn(p, "focus", fn this, _ ->
      focus_element(this_nid(this))
      :undefined
    end)

    def_fn(p, "blur", fn this, _ ->
      if st().focus_ed == this_nid(this), do: ed_blur()
      :undefined
    end)

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
      out({:submit, form_index(this_nid(this))})
      :undefined
    end)

    def_fn(p, "requestSubmit", fn this, _ ->
      nid = this_nid(this)
      if dispatch(nid, "submit", %{}) == :ok, do: out({:submit, form_index(nid)})
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

  @doc "The `<script>` element being run (`document.currentScript`), or nil."
  def set_current_script(nid), do: put_st(%{st() | current_script: nid, write_after: nil})

  # `document.write`: what is written goes in after the running script (after what an earlier
  # write of the same script put there), or at the end of the body when nothing is running
  defp write_html(html) do
    ids = parse_fragment(html)
    s = st()

    cond do
      s.write_after != nil ->
        adjacent(s.write_after, "afterend", ids)

      s.current_script != nil ->
        adjacent(s.current_script, "afterend", ids)

      body = find_tag(s.doc, "body") ->
        adjacent(body, "beforeend", ids)

      true ->
        :ok
    end

    if ids != [], do: put_st(%{st() | write_after: List.last(ids)})
    :undefined
  end

  defp install_document(p) do
    for name <- ~w(write writeln) do
      def_fn(p, name, fn _this, args ->
        text = Enum.map_join(args, "", &to_str/1)
        write_html(if name == "writeln", do: text <> "\n", else: text)
      end)
    end

    for name <- ~w(open close) do
      def_fn(p, name, fn _this, _ -> :undefined end)
    end

    def_fn(p, "getElementById", fn _this, args ->
      id = to_str(arg(args, 0))
      wrap_or_null(element_by_id(st().doc, id))
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
      navigate_to(resolve_url(to_str(arg(args, 0))))
      :undefined
    end)

    def_fn(loc, "replace", fn _this, args ->
      navigate_to(resolve_url(to_str(arg(args, 0))), :replace)
      :undefined
    end)

    def_fn(loc, "reload", fn _this, _ ->
      out({:reload})
      :undefined
    end)

    def_fn(loc, "toString", fn _this, _ -> st().url end)
    def_fn(loc, "valueOf", fn this, _ -> this end)

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

    def_fn(storage, "getItem", fn this, args ->
      storage_read(storage_area(this), to_str(arg(args, 0))) || :null
    end)

    def_fn(storage, "setItem", fn this, args ->
      storage_set(storage_area(this), to_str(arg(args, 0)), to_str(arg(args, 1)))
      :undefined
    end)

    def_fn(storage, "removeItem", fn this, args ->
      storage_remove(storage_area(this), to_str(arg(args, 0)))
      :undefined
    end)

    def_fn(storage, "clear", fn this, _ ->
      storage_clear(storage_area(this))
      :undefined
    end)

    def_fn(storage, "key", fn this, args ->
      storage_key(storage_area(this), to_int(arg(args, 0))) || :null
    end)

    install_usp(proto({:dom, :usp}))

    win = proto({:dom, :window})

    for name <- ~w(alert focus blur print) do
      def_fn(win, name, fn _this, _ -> :undefined end)
    end

    # `window.open` opens the address in a new tab; there is no window to hand back
    def_fn(win, "open", fn _this, args ->
      url = to_str(arg(args, 0))
      if url not in ["", "about:blank"], do: out({:open_tab, resolve_url(url)})
      :null
    end)

    def_fn(win, "scrollTo", fn _this, args -> scroll_args(args, false) end)
    def_fn(win, "scroll", fn _this, args -> scroll_args(args, false) end)
    def_fn(win, "scrollBy", fn _this, args -> scroll_args(args, true) end)
  end

  # `pushState` and `replaceState`: the address must be of this page's origin
  defp history_state(args, kind) do
    state = arg(args, 0)

    url =
      case arg(args, 2) do
        v when v in [:undefined, :null] ->
          st().url

        v ->
          url = resolve_url(to_str(v))

          if same_origin?(url, st().url),
            do: url,
            else:
              throw_error(
                "SecurityError",
                "A history state object with URL '#{url}' cannot be created in a document with origin '#{origin_of(st().url)}'."
              )
      end

    if kind == :push, do: hist_push(url, state), else: hist_replace(url, state)
    out({:history, kind, url})
    :undefined
  end

  defp same_origin?(a, b), do: origin_of(a) == origin_of(b)

  defp origin_of(url) do
    case URI.parse(url) do
      %URI{scheme: "file"} -> "file://"
      %URI{scheme: scheme, host: host, port: port} -> "#{scheme}://#{host}:#{port}"
    end
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

  @node_constants [
    {"ELEMENT_NODE", 1},
    {"ATTRIBUTE_NODE", 2},
    {"TEXT_NODE", 3},
    {"CDATA_SECTION_NODE", 4},
    {"PROCESSING_INSTRUCTION_NODE", 7},
    {"COMMENT_NODE", 8},
    {"DOCUMENT_NODE", 9},
    {"DOCUMENT_TYPE_NODE", 10},
    {"DOCUMENT_FRAGMENT_NODE", 11},
    {"DOCUMENT_POSITION_DISCONNECTED", 1},
    {"DOCUMENT_POSITION_PRECEDING", 2},
    {"DOCUMENT_POSITION_FOLLOWING", 4},
    {"DOCUMENT_POSITION_CONTAINS", 8},
    {"DOCUMENT_POSITION_CONTAINED_BY", 16},
    {"DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC", 32}
  ]

  # the window-level names of the running realm: `window`, `document`, `location`, its size, ...
  @doc false
  def declare_window(scope) do
    # globals that point into the document
    window = win_host()
    declare(scope, "window", window)
    # `this` at the top of a classic script is the window
    declare(scope, :this, window)
    declare(scope, "self", window)
    # there are no frames: the window is its own top and parent
    declare(scope, "top", aux_host(:window, :window))
    declare(scope, "parent", Interp.get(window, "parent"))
    declare(scope, "frames", window)
    declare(scope, "opener", :null)
    declare(scope, "closed", false)
    declare(scope, "name", "")
    declare(scope, "isSecureContext", secure_context?(st().url))
    declare(scope, "globalThis", window)
    declare(scope, "document", wrap(st().doc))
    declare(scope, "location", loc_host())
    declare(scope, "history", hist_host())
    declare(scope, "localStorage", storage_host(:local))
    declare(scope, "sessionStorage", storage_host(:session))

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
  end

  defp install_globals(scope, event_target, node_proto, element, text, document, event) do
    # constructors, so `instanceof` works (and `new Event(...)`)
    ctor(scope, "EventTarget", event_target, fn _, _ -> :undefined end)
    node_ctor = ctor(scope, "Node", node_proto, fn _, _ -> :undefined end)

    for {name, v} <- @node_constants, target <- [node_ctor, node_proto] do
      put_hidden(target, name, v)
    end

    ctor(scope, "Element", element, fn _, _ -> :undefined end)
    ctor(scope, "HTMLElement", element, fn this, _ -> html_element_ctor(this) end)
    # `el instanceof HTMLAnchorElement` and the like
    for {name, tags} <- @element_classes do
      p = new_object([], element)
      for tag <- tags, do: put_proto({:dom, {:tag, tag}}, p)
      ctor(scope, name, p, fn _, _ -> throw_error("TypeError", "Illegal constructor") end)
      # `Object.prototype.toString.call(el)`: Vue and others tell what is not worth a proxy by it
      Interp.put_tag(p, name)
    end

    for {proto, tag} <- [
          {element, "HTMLElement"},
          {text, "Text"},
          {document, "HTMLDocument"},
          {event, "Event"},
          {node_proto, "Node"}
        ],
        do: Interp.put_tag(proto, tag)

    for name <- ~w(SVGElement SVGAElement ShadowRoot DocumentFragment Comment KeyframeEffect) do
      ctor(scope, name, new_object([], element), fn _, _ -> :undefined end)
    end

    ctx_proto = new_object([])
    install_canvas_context(ctx_proto)
    Process.put(:canvas_ctx_proto, ctx_proto)

    ctor(scope, "CanvasRenderingContext2D", ctx_proto, fn _, _ ->
      throw_error("TypeError", "Illegal constructor")
    end)

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
            {"timeStamp", Browser.JS.Builtins.perf_now()}
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

    declare_window(scope)
    subscribe_storage()

    navigator =
      new_object([
        {"userAgent", Browser.Fetch.user_agent()},
        {"vendor", "Google Inc."},
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
