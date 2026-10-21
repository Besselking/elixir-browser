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
  `{:history, :push | :replace, url}`, `{:navigate, url}`, `{:open_tab, url}`, `{:reload}`, `{:submit, form}`,
  `{:clipboard, text}`, `{:download, url, name, data}`.
  """

  import Kernel, except: [node: 1]
  import Browser.JS.Interp, except: [get: 2, put: 3]
  import Browser.Re, only: [re: 1, split_words: 1]
  alias Browser.JS.Interp
  alias Browser.JS.Str
  require Browser.JS.Obj, as: Obj

  @void ~w(area base br col embed hr img input link meta param source track wbr)

  # ── state ──────────────────────────────────────────────────

  # (`:erlang.get/1` is an instruction of the JIT; `Process.get/1` is a call around it, and the
  # state is read for each node)
  defp st do
    case :erlang.get(:dom) do
      :undefined -> nil
      s -> s
    end
  end

  defp put_st(s), do: Process.put(:dom, s)

  # The fields of the state (and of the saved fields of a realm) that hold no JS value: the
  # node table, the indexes of the ids and of the attribute values, the boxes, node ids, counts
  # and sizes. The JS collector reads each integer as a heap id, so these fields can keep dead
  # objects alive, and the node table makes each collection long. (The node ids in them are
  # read by `gc_node_roots/1` and cleaned by `gc_sweep/0`.)
  @gc_fields ~w(nodes ids aidx iframes rects rev next next_nid usp doc main frames meta fdirty
                ce_done current_script write_after focus_ed focus_ctl scroll content width height
                hist_idx history_before tags)a

  @doc false
  # Check mode: the fields that `gc_begin/2` leaves out, which must hold no JS value.
  def gc_left_out(s),
    do: [Map.take(s, @gc_fields) | for({_, r} <- s.realms, do: Map.take(r.fields, @gc_fields))]

  # ── the JS collector and the node table ────────────────────
  #
  # The JS collector (`Browser.JS.GC.collect/0`) also frees the nodes that nothing can reach
  # any more, and their wrappers and listeners. A node is live when its tree is live. The tree
  # of a node is what the node links reach: up through `parent` (and `shost` from a shadow
  # root to its host), down through `kids`, `shadow` and `content`. A tree is live when it
  # has a root node (a document of a realm, a frame, the focus: `gc_node_roots/1`), or when
  # the walk of the JS heap finds the id of one of its nodes. A wrapper holds the id of its
  # node (`host: {Browser.JS.DOM, nid}`), the `classList`, `style` and `dataset` objects
  # hold it in a tuple, and the environment of a native can hold node ids as plain integers.
  # So the walk reads each plain integer in such Elixir data that is the id of a node as a
  # reference to it (`Browser.JS.GC.push_nids/3`). A stray integer there (a table of
  # characters of a native) can keep a dead tree alive, but a node that a script can reach is
  # never freed. A JS value (a number) is not a reference to a node. The wrapper, the
  # `classList`, `style` and
  # `dataset` objects, the listeners and the canvas context of a node are not roots: the walk
  # goes into them when it finds the node live (`gc_reach/1`), and what they hold can make
  # more trees live (as with ephemerons). Then `gc_sweep/0` takes the dead nodes out of the
  # node table and out of each map that names them. The node ids are never used again, and
  # `node/1` reads a missing id as an empty detached node.

  @doc """
  True for a process key of a node (the node id is the second element): its canvas, the
  context of its canvas, the functions of its handler attributes, the load of its frame,
  the `document.open` of a document.
  """
  defguard gc_node_key?(k)
           when is_tuple(k) and tuple_size(k) >= 2 and is_integer(elem(k, 1)) and
                  elem(k, 0) in [:canvas, :canvas_ctx, :inline_handler, :dom_frame_tok, :dom_open]

  @doc """
  The start of a collection. `s` is the state, and `keys` are the process keys of the nodes
  (`gc_node_key?/1`) with their values. Gives the part of the state that the collector walks
  as a root, the terms that the live root trees hold for the walk (their wrappers and
  listeners), and the bound of the node ids. The root part is the state without the fields
  that hold no JS value (a node map holds only primitives and node ids), and without the
  wrappers and the listeners of the nodes. The other fields (the wrappers and the listeners
  of the windows, the custom elements, the history states and the saved keys of the realms)
  can hold JS values. What `gc_reach/1` and `gc_sweep/0` need is under the process key
  `:js_gc_dom` until `gc_sweep/0`.
  """
  def gc_begin(s, keys) do
    {wroot, extra} =
      :maps.fold(
        fn
          # (the wrapper of a node: `gc_down/3` reads it from the wrappers)
          k, _w, acc when is_integer(k) ->
            acc

          {:aux, data} = k, w, {root, extra} ->
            case aux_nid(data) do
              nil -> {Map.put(root, k, w), extra}
              nid -> {root, Map.update(extra, nid, [w], &[w | &1])}
            end

          k, w, {root, extra} ->
            {Map.put(root, k, w), extra}
        end,
        {%{}, %{}},
        s.wrappers
      )

    {lroot, extra} =
      :maps.fold(
        fn
          k, l, {root, extra} when is_integer(k) -> {root, Map.update(extra, k, [l], &[l | &1])}
          k, l, {root, extra} -> {Map.put(root, k, l), extra}
        end,
        {%{}, extra},
        s.listeners
      )

    {open, extra} =
      :lists.foldl(
        fn
          {{:dom_open, doc}, _}, {open, extra} ->
            {[doc | open], extra}

          {k, v}, {open, extra} when elem(k, 0) in [:canvas_ctx, :inline_handler] ->
            {open, Map.update(extra, elem(k, 1), [v], &[v | &1])}

          _, acc ->
            acc
        end,
        {[], extra},
        keys
      )

    limit = s.next + 1
    words = div(limit, 64) + 1
    # (the word after the bitmap counts the live nodes)
    bits = {:atomics.new(words + 1, signed: false), words * 64}
    ctx = %{nodes: s.nodes, wrappers: s.wrappers, extra: extra, bits: bits, pkeys: keys}
    Process.put(:js_gc_dom, ctx)
    terms = :lists.foldl(&gc_tree(ctx, &1, &2), [], open ++ gc_node_roots(s))

    realms =
      for {d, r} <- s.realms, into: %{}, do: {d, %{r | fields: Map.drop(r.fields, @gc_fields)}}

    root = %{Map.drop(s, @gc_fields) | realms: realms, wrappers: wroot, listeners: lroot}
    {root, terms, limit}
  end

  # the node of the host data of a `classList`, `style` or `dataset` object, or nil (a window,
  # a location, a history or a storage belongs to a realm)
  defp aux_nid({k, nid}) when k in [:classlist, :style, :dataset] and is_integer(nid), do: nid
  defp aux_nid({:style, nid, :computed}) when is_integer(nid), do: nid
  defp aux_nid(_), do: nil

  # The nodes that are live whatever the walk finds: the documents of the realms and their
  # frames, the scripts that run, the focus. (A field of a realm that is not saved is not
  # there, so the fields are read with `Map.get/2`.)
  defp gc_node_roots(s) do
    realm = fn f -> [f[:doc], f[:current_script], f[:write_after]] end
    metas = for {d, m} <- s.meta, x <- [d, m[:iframe], m[:parent]], do: x

    [s.main, s.focus_ed, s.focus_ctl | realm.(s)] ++
      Map.keys(s.realms) ++
      Map.keys(s.frames) ++
      Map.values(s.frames) ++
      metas ++
      MapSet.to_list(s.fdirty) ++ Enum.flat_map(Map.values(s.realms), &realm.(&1.fields))
  end

  @doc """
  The walk of the JS heap found the plain integer `nid`, which is the id of a node. When the
  node is not live yet, its tree becomes live: gives the terms that the nodes of the tree
  keep alive (their wrappers, listeners and canvas contexts), for the walk.
  """
  def gc_reach(nid), do: gc_tree(Process.get(:js_gc_dom), nid, [])

  defp gc_tree(%{nodes: nodes, bits: bits} = ctx, nid, acc) when is_integer(nid) do
    if not gc_live?(bits, nid) and is_map_key(nodes, nid) do
      acc = gc_down(ctx, [root_in(nodes, nid)], acc)
      # (a node that the kids of its parent do not list is not in the tree of its root)
      if gc_live?(bits, nid), do: acc, else: gc_down(ctx, [nid], acc)
    else
      acc
    end
  end

  defp gc_tree(_ctx, _nid, acc), do: acc

  # Marks the nodes of the lists in `work` and the nodes below them live, and adds what they
  # hold to `acc`. A node that is live already is the top of a live subtree: the walk stops
  # there.
  defp gc_down(_ctx, [], acc), do: acc
  defp gc_down(ctx, [[] | work], acc), do: gc_down(ctx, work, acc)
  defp gc_down(ctx, [[k | ks] | work], acc), do: gc_down(ctx, [k, ks | work], acc)

  defp gc_down(%{nodes: nodes, bits: bits} = ctx, [nid | work], acc) do
    case nodes do
      %{^nid => n} ->
        if gc_mark(bits, nid) do
          acc =
            case ctx.wrappers do
              %{^nid => w} -> [w | acc]
              _ -> acc
            end

          acc =
            case ctx.extra do
              %{^nid => l} -> [l | acc]
              _ -> acc
            end

          # (the document of the node, which `ownerDocument` gives)
          acc = if n.doc == nid, do: acc, else: gc_tree(ctx, n.doc, acc)

          # (most nodes have no template content and no shadow root)
          work =
            case n do
              %{content: nil, shadow: nil} -> work
              %{content: c, shadow: sh} -> [c, sh | work]
            end

          gc_down(ctx, [n.kids | work], acc)
        else
          gc_down(ctx, work, acc)
        end

      _ ->
        gc_down(ctx, work, acc)
    end
  end

  # The live nodes are a bitmap with one bit for each node id below `cap` (each id in the
  # node table is below `next`, and `cap` is above it). The word after the bitmap counts the
  # live nodes, so the sweep does nothing when all are live.
  defp gc_live?({bits, cap}, nid) when is_integer(nid) and nid >= 0 and nid < cap do
    word = :atomics.get(bits, :erlang.bsr(nid, 6) + 1)
    :erlang.band(word, :erlang.bsl(1, :erlang.band(nid, 63))) != 0
  end

  defp gc_live?(_bits, _nid), do: false

  # marks `nid` live; false when it was live before (or has no bit)
  defp gc_mark({bits, cap}, nid) when nid >= 0 and nid < cap do
    i = :erlang.bsr(nid, 6) + 1
    bit = :erlang.bsl(1, :erlang.band(nid, 63))
    word = :atomics.get(bits, i)

    if :erlang.band(word, bit) == 0 do
      :atomics.put(bits, i, :erlang.bor(word, bit))
      :atomics.add(bits, div(cap, 64) + 1, 1)
      true
    else
      false
    end
  end

  defp gc_mark(_bits, _nid), do: false

  @doc """
  The end of a collection: the nodes that are not live leave the node table, with their
  wrappers, listeners, entries of the indexes and process keys. The walk did not mark their
  wrappers, so the collector frees them. Gives the number of nodes that left.
  """
  def gc_sweep do
    %{bits: {atomics, cap} = bits, pkeys: keys} = Process.delete(:js_gc_dom)
    s = st()
    live? = &gc_live?(bits, &1)
    size = map_size(s.nodes)
    live = :atomics.get(atomics, div(cap, 64) + 1)

    for {k, _} <- keys, elem(k, 0) != :dom_open, not live?.(elem(k, 1)), do: Process.delete(k)

    # (a wrapper of `classList`, `style` or `dataset` goes with its node, the wrappers of a
    # realm stay)
    wrappers =
      gc_filter(s.wrappers, fn
        k when is_integer(k) -> live?.(k)
        {:aux, data} -> (nid = aux_nid(data)) == nil or live?.(nid)
        _ -> true
      end)

    listeners = gc_filter(s.listeners, &(not is_integer(&1) or live?.(&1)))

    s =
      cond do
        live == size -> s
        2 * live < size -> gc_keep(s, live?, gc_live_nodes(s.nodes, atomics, div(cap, 64)))
        true -> gc_drop(s, live?)
      end

    put_st(%{s | wrappers: wrappers, listeners: listeners})
    size - live
  end

  # `map` without the keys that `keep?` refuses; the same term when it keeps all of them
  defp gc_filter(map, keep?) do
    case :maps.fold(fn k, _, acc -> if keep?.(k), do: acc, else: [k | acc] end, [], map) do
      [] -> map
      dead when 2 * length(dead) > map_size(map) -> :maps.filter(fn k, _ -> keep?.(k) end, map)
      dead -> Map.drop(map, dead)
    end
  end

  # The live nodes, from the bitmap: when most nodes are dead, this costs less than a walk of
  # the node table.
  defp gc_live_nodes(nodes, atomics, words) do
    gc_live_nodes(nodes, atomics, words, [])
  end

  defp gc_live_nodes(_nodes, _atomics, 0, acc), do: :maps.from_list(acc)

  defp gc_live_nodes(nodes, atomics, i, acc) do
    acc = gc_word_nodes(nodes, :atomics.get(atomics, i), (i - 1) * 64, acc)
    gc_live_nodes(nodes, atomics, i - 1, acc)
  end

  defp gc_word_nodes(_nodes, 0, _nid, acc), do: acc

  defp gc_word_nodes(nodes, word, nid, acc) do
    acc =
      case :erlang.band(word, 1) == 1 and nodes do
        %{^nid => n} -> [{nid, n} | acc]
        _ -> acc
      end

    gc_word_nodes(nodes, :erlang.bsr(word, 1), nid + 1, acc)
  end

  # The state with the node table `nodes` (most nodes were dead): the indexes keep the live
  # nodes only. They are small next to the dead nodes, so a walk of them costs less than a
  # removal for each dead node.
  defp gc_keep(s, live?, nodes) do
    ids =
      :maps.fold(
        fn id, list, acc ->
          case Enum.filter(list, live?) do
            ^list -> acc
            [] -> Map.delete(acc, id)
            l -> Map.put(acc, id, l)
          end
        end,
        s.ids,
        s.ids
      )

    aidx =
      :maps.map(
        fn _name, vals ->
          :maps.fold(
            fn v, set, acc ->
              case :maps.filter(fn nid, _ -> live?.(nid) end, set) do
                kept when map_size(kept) == map_size(set) -> acc
                kept when map_size(kept) == 0 -> Map.delete(acc, v)
                kept -> Map.put(acc, v, kept)
              end
            end,
            vals,
            vals
          )
        end,
        s.aidx
      )

    gc_rest(%{s | nodes: nodes, ids: ids, aidx: aidx}, live?)
  end

  # The state without the dead nodes (a few of them): each one leaves the indexes.
  defp gc_drop(s, live?) do
    dead =
      :maps.fold(
        fn nid, n, acc -> if live?.(nid), do: acc, else: [{nid, n} | acc] end,
        [],
        s.nodes
      )

    aidx = s.aidx
    ids = :lists.foldl(fn {nid, n}, ids -> unindex(ids, element_id(n), nid) end, s.ids, dead)
    indexed = for {_, n} = e <- dead, indexed?(n, aidx), do: e

    aidx =
      if indexed == [],
        do: aidx,
        else:
          :maps.map(
            fn name, vals ->
              :lists.foldl(
                fn {nid, n}, acc -> attr_out(acc, attr_value(n, name), nid) end,
                vals,
                indexed
              )
            end,
            aidx
          )

    nodes = Map.drop(s.nodes, for({nid, _} <- dead, do: nid))
    gc_rest(%{s | nodes: nodes, ids: ids, aidx: aidx}, live?)
  end

  # the other maps and sets of node ids: the `<iframe>`s and the custom elements made
  defp gc_rest(s, live?) do
    ce_done = fn set -> if MapSet.size(set) == 0, do: set, else: MapSet.filter(set, live?) end

    realms =
      for {d, r} <- s.realms, into: %{} do
        case r.fields do
          %{ce_done: set} = f -> {d, %{r | fields: %{f | ce_done: ce_done.(set)}}}
          _ -> {d, r}
        end
      end

    %{
      s
      | iframes: gc_filter(s.iframes, live?),
        ce_done: ce_done.(s.ce_done),
        realms: realms
    }
  end

  # a node of a frame that was torn down is gone from the map, but a page may still hold it:
  # it then reads as an empty, detached node
  defp node(nid) do
    case st().nodes do
      %{^nid => n} -> n
      _ -> missing_node(nid)
    end
  end

  # `node/1` in the node table `nodes`
  defp node_in(nodes, nid) do
    case nodes do
      %{^nid => n} -> n
      _ -> missing_node(nid)
    end
  end

  defp missing_node(nid) do
    %{
      id: nid,
      kind: :text,
      tag: nil,
      attrs: [],
      internal: [],
      props: %{},
      kids: [],
      parent: nil,
      text: "",
      content: nil,
      shost: nil,
      shadow: nil,
      doc: nil
    }
  end

  # The elements by `id` attribute: name => node ids (any element of any tree, attached or not).
  # `window.Foo` and bare names that nothing declares look an element up by id, so this is kept
  # up to date by the writes to the node table instead of being rebuilt after every change.
  defp element_id(%{kind: :element, attrs: attrs}) do
    case List.keyfind(attrs, "id", 0) do
      {_, id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp element_id(_), do: nil

  defp reindex(ids, nid, old, new) do
    o = element_id(old)
    n = element_id(new)

    cond do
      o == n -> ids
      true -> ids |> unindex(o, nid) |> index_in(n, nid)
    end
  end

  defp unindex(ids, nil, _), do: ids

  defp unindex(ids, id, nid) do
    case ids do
      %{^id => [^nid]} -> Map.delete(ids, id)
      %{^id => list} -> Map.put(ids, id, List.delete(list, nid))
      _ -> ids
    end
  end

  defp index_in(ids, nil, _), do: ids
  defp index_in(ids, id, nid), do: Map.update(ids, id, [nid], &[nid | &1])

  # The elements by the value of an attribute, for a few names: name => value => set of node
  # ids (`%{nid => true}`, `st().aidx`). A selector such as `[data-id="7"]` gets its
  # candidates from it (see `attr_candidates/3`). A name gets an index the first time that a
  # search uses it, and at most @attr_names names get one. The writes to the node table keep it
  # up to date, as they keep `ids`. An element with no parent is the top of its tree, and a
  # search never gives the top of a tree, so the index does not have it. A page that draws a
  # list again and again (`innerHTML`) thus does not give a value a long list of old elements.
  # Many elements can have one value (`role="option"`), so each value has a set and not a list:
  # a change of one element does not walk all of them.
  @attr_names 4

  defp attr_value(%{kind: :element, attrs: attrs, parent: p}, name) when p != nil do
    case List.keyfind(attrs, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp attr_value(_, _), do: nil

  # the indexes after a write of node `nid`: `old` is the node before (nil for a new node)
  defp reindex_all(s, _nid, %{attrs: attrs, parent: p}, %{attrs: attrs, parent: q})
       when p == q or (p != nil and q != nil),
       do: s

  defp reindex_all(s, nid, old, new),
    do: %{s | ids: reindex(s.ids, nid, old, new), aidx: reindex_attrs(s.aidx, nid, old, new)}

  defp reindex_attrs(aidx, _nid, _old, _new) when map_size(aidx) == 0, do: aidx

  # Most writes are of text nodes and of elements with no indexed name. For them the index
  # does not change, so this function does not fold over the names.
  defp reindex_attrs(aidx, nid, old, new) do
    if indexed?(old, aidx) or indexed?(new, aidx) do
      :lists.foldl(
        fn {name, vals}, acc ->
          o = attr_value(old, name)
          n = attr_value(new, name)
          if o == n, do: acc, else: %{acc | name => vals |> attr_out(o, nid) |> attr_in(n, nid)}
        end,
        aidx,
        :maps.to_list(aidx)
      )
    else
      aidx
    end
  end

  # True when the node can be in the index: an element with a parent and an attribute with a
  # name of `aidx` (for all other nodes `attr_value/2` gives nil)
  defp indexed?(%{kind: :element, attrs: attrs, parent: p}, aidx) when p != nil,
    do: indexed_name?(attrs, aidx)

  defp indexed?(_, _), do: false

  defp indexed_name?([{k, _} | rest], aidx), do: is_map_key(aidx, k) or indexed_name?(rest, aidx)
  defp indexed_name?([], _), do: false

  defp attr_in(vals, nil, _), do: vals
  defp attr_in(vals, v, nid), do: Map.update(vals, v, %{nid => true}, &Map.put(&1, nid, true))

  defp attr_out(vals, nil, _), do: vals

  defp attr_out(vals, v, nid) do
    case vals do
      %{^v => %{^nid => _} = set} when map_size(set) == 1 -> Map.delete(vals, v)
      %{^v => set} -> %{vals | v => Map.delete(set, nid)}
      _ -> vals
    end
  end

  # the index of the values of `name`, made now when the name has none; nil when the name has
  # none and the index has no room for it
  defp attr_index(name) do
    s = st()

    case s.aidx do
      %{^name => vals} ->
        vals

      aidx when map_size(aidx) < @attr_names ->
        vals =
          Enum.reduce(s.nodes, %{}, fn {nid, n}, acc ->
            attr_in(acc, attr_value(n, name), nid)
          end)

        put_st(%{s | aidx: Map.put(aidx, name, vals)})
        vals

      _ ->
        nil
    end
  end

  # The tokens of the `class` attribute of an element, kept on the node as `cls`:
  # `{value, tokens}`. Selectors and `classList` read the tokens many times for each change of
  # the attribute, and a split of the value at each read was a large part of a search. Each
  # write to the node table goes through this function, so the tokens follow the attribute.
  # A reader also compares the value (`class_tokens/1`), so it never uses tokens of an old
  # value.
  defp with_classes(%{attrs: attrs} = n) when attrs != [] do
    case List.keyfind(attrs, "class", 0) do
      {_, v} when is_binary(v) ->
        case n do
          %{cls: {^v, _}} -> n
          _ -> Map.put(n, :cls, {v, split_words(v)})
        end

      _ ->
        n
    end
  end

  defp with_classes(n), do: n

  defp class_tokens(n) do
    case List.keyfind(n.attrs, "class", 0) do
      {_, v} ->
        case n do
          %{cls: {^v, tokens}} -> tokens
          _ -> split_words(v)
        end

      nil ->
        []
    end
  end

  defp put_node(n), do: put_st(put_node_in(st(), n))

  # `put_node/1` on a state that the caller holds
  defp put_node_in(s, n) do
    n = with_classes(n)
    s = changed(s, n.doc)
    s = reindex_all(s, n.id, Map.get(s.nodes, n.id), n)
    %{s | nodes: Map.put(s.nodes, n.id, n), rev: s.rev + 1}
  end

  # the state after a change of the tree of document `doc` (the layout must see it again)
  defp changed(s, doc) do
    if doc == s.main or doc == nil,
      do: %{s | dirty: true},
      else: %{s | fdirty: MapSet.put(s.fdirty, doc)}
  end

  defp update_node(nid, fun), do: put_node(fun.(node(nid)))

  defp new_node(fields) do
    {id, s} = add_node(st(), fields)
    put_st(s)
    id
  end

  # `new_node/1` on a state that the caller holds: gives the new id and the state. A fragment
  # of many nodes (`build_in/3`) is made with one read and one write of the process state.
  defp add_node(s, fields), do: put_new(s, Map.merge(blank_node(s.next, s.doc), fields))

  # a new node with id `id` in document `doc`, with the fields that `new_node/1` gives when it is
  # not told otherwise
  defp blank_node(id, doc) do
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
      # a shadow root (a fragment) knows its host, a host its shadow root
      shost: nil,
      shadow: nil,
      # the document the node belongs to (a document node's is itself)
      doc: doc
    }
  end

  # The state when the new node `n` takes its id: the indexes and the `<iframe>`s have it, and
  # `next` and `rev` go up. Gives `n` with the tokens of its `class`. The caller puts `n` in the
  # node table.
  defp index_node(s, n) do
    id = n.id

    # (the checks that frames need are only made once the page has an <iframe>; `iframes` has
    # each `<iframe>` element, see `frames_in/1`)
    iframes =
      if n.tag == "iframe" do
        Process.put(:dom_has_iframe, true)
        Map.put(s.iframes, id, true)
      else
        s.iframes
      end

    n = with_classes(n)

    {n,
     %{
       s
       | next: id + 1,
         ids: reindex(s.ids, id, nil, n),
         aidx: reindex_attrs(s.aidx, id, nil, n),
         iframes: iframes,
         rev: s.rev + 1
     }
     |> add_tag(n)}
  end

  # The tags of the elements are in `tags`: each tag that an element of the node table has
  # had. A new element is the one way into the table (`index_node/2`, `build_list_fast/3`),
  # and the tag of an element never changes. A tag stays when its last element goes, so
  # `tags` has the tag of each element and maybe more. It is enough for `tag_absent?/2`.
  defp add_tag(s, %{kind: :element, tag: t}) when is_binary(t) do
    case s do
      %{tags: %{^t => _}} -> s
      _ -> Map.put(s, :tags, Map.put(Map.get(s, :tags, %{}), t, true))
    end
  end

  defp add_tag(s, _n), do: s

  @doc false
  # Check: the tags of the elements of the node table that `tags` does not have (an empty
  # list when `tags` is correct).
  def missing_tags do
    s = st()
    tags = Map.get(s, :tags, %{})

    for {_, %{kind: :element, tag: t}} <- s.nodes,
        is_binary(t),
        not is_map_key(tags, t),
        uniq: true,
        do: t
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

  # A script of the page that runs code of a frame (Speedometer calls a function of the frame
  # for each step) swaps the realm for each node it touches, so the swap must be cheap. The
  # functions below read and write the fields and the keys with one map update and one
  # process key operation each. They do not walk lists and do not make closures.
  s_var = Macro.var(:s, nil)
  f_var = Macro.var(:f, nil)
  keys_var = Macro.var(:saved, nil)

  defp take_fields(unquote(s_var)) do
    %{unquote_splicing(for k <- @realm_fields, do: {k, quote(do: unquote(s_var).unquote(k))})}
  end

  defp put_fields(unquote(s_var), unquote(f_var)) do
    %{
      unquote(s_var)
      | unquote_splicing(
          for k <- @realm_fields, do: {k, quote(do: :erlang.map_get(unquote(k), unquote(f_var)))}
        )
    }
  end

  defp take_keys do
    %{
      unquote_splicing(
        for k <- @realm_keys do
          {k,
           quote do
             case :erlang.get(unquote(k)) do
               :undefined -> :__unset
               v -> v
             end
           end}
        end
      )
    }
  end

  defp put_keys(unquote(keys_var)) do
    unquote_splicing(
      for k <- @realm_keys do
        quote do
          case :erlang.map_get(unquote(k), unquote(keys_var)) do
            :__unset -> :erlang.erase(unquote(k))
            v -> :erlang.put(unquote(k), v)
          end
        end
      end
    )

    :ok
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

  # The documents of the realms that were entered and run now, the last first, are in
  # `:dom_stack`. A frame can go while its realm is on it: a script of the frame took its own
  # `<iframe>` away (also through a function of the page). Then the realm's entry stays in the
  # table until the last run of the realm ends, so that the code after the removal runs to its
  # end (`destroy_realm/1` puts the document in `:dom_dead`).
  defp enter_realm(doc, fun) do
    prev = swap_realm(doc)
    stack = Process.get(:dom_stack, [])
    Process.put(:dom_stack, [doc | stack])

    try do
      fun.()
    after
      Process.put(:dom_stack, stack)
      swap_realm(prev)
      # (the realm went while it ran: what it left in the table goes with it)
      dead = Process.get(:dom_dead, [])

      if doc in dead and doc not in stack do
        Process.put(:dom_dead, List.delete(dead, doc))
        put_st(%{st() | realms: Map.delete(st().realms, doc)})
      end
    end
  end

  # makes `doc` the running document; returns the one that was
  defp swap_realm(doc) do
    s = st()
    prev = s.doc
    {%{fields: fields, keys: keys}, realms} = Map.pop!(s.realms, doc)
    saved = %{fields: take_fields(s), keys: take_keys()}
    put_st(put_fields(%{s | realms: Map.put(realms, prev, saved)}, fields))
    put_keys(keys)
    prev
  end

  @doc "The frame document a timer made now belongs to (nil in the page's own document)."
  def timer_realm do
    case st() do
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

  @doc "The document of the running realm, or nil in a runtime with no document."
  def current_doc_or_nil do
    case st() do
      %{doc: d} -> d
      _ -> nil
    end
  end

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
      kids = build_all(raw, doc)
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
    aidx = s.aidx

    # One walk of the node table gives the nodes of the document, the id index without them,
    # and the short list of the nodes that the attribute index has.
    {ids, id_index, indexed} =
      :maps.fold(
        fn
          nid, %{doc: ^doc} = n, {ids, id_index, indexed} ->
            id_index = unindex(id_index, element_id(n), nid)

            {[nid | ids], id_index,
             if(indexed?(n, aidx), do: [{nid, n} | indexed], else: indexed)}

          _, _, acc ->
            acc
        end,
        {[], s.ids, []},
        s.nodes
      )

    iframe = s.meta |> Map.get(doc, %{}) |> Map.get(:iframe)
    frames = if iframe, do: Map.delete(s.frames, iframe), else: s.frames

    aidx =
      if indexed == [],
        do: aidx,
        else:
          :maps.map(
            fn name, vals ->
              :lists.foldl(
                fn {nid, n}, acc -> attr_out(acc, attr_value(n, name), nid) end,
                vals,
                indexed
              )
            end,
            aidx
          )

    # (the global scope of the realm, for its entries in the code cache)
    global =
      case s.realms do
        _ when s.doc == doc -> Process.get(:js_global)
        %{^doc => %{fields: _, keys: %{js_global: g}}} -> g
        _ -> nil
      end

    if is_integer(global) do
      Browser.JS.Compile.drop_realm(global)
      # (the functions of the realm leave the built-in objects that all realms share)
      if Browser.JS.Intrinsics.restore(global) > 0, do: Browser.JS.Editing.restored()
    end

    # (a realm that runs now keeps its entry until its run ends, see `enter_realm/2`)
    running? = s.doc == doc or doc in Process.get(:dom_stack, [])
    realms = if running?, do: s.realms, else: Map.delete(s.realms, doc)
    if running?, do: Process.put(:dom_dead, [doc | Process.get(:dom_dead, [])])

    # The timers of the realm go with it. A timer holds its callback, and the callback holds
    # the global scope of the realm: the whole page stays alive while the timer is there.
    case Process.get(:js_timers) do
      timers when is_list(timers) ->
        Process.put(:js_timers, Enum.reject(timers, &(&1[:realm] == doc)))

      _ ->
        :ok
    end

    # (the functions of the editing prelude of the realm go back to their boot state, see
    # `Browser.JS.Intrinsics`: the realm's document no longer has the prelude)
    with %MapSet{} = loaded <- Process.get(:editing_loaded),
         do: Process.put(:editing_loaded, MapSet.delete(loaded, doc))

    # All the host objects of the realm go: the window and the location, and also the history
    # and the storages. A wrapper is a root of the collector and holds a prototype of the
    # realm, thus the realm's global scope. (A storage wrapper holds no data: its items are in
    # the state of the page.)
    dead_aux = for {{:aux, d} = k, _} <- s.wrappers, aux_doc(d) == doc, do: k

    # The maps without the nodes of the document (`ids`). When the document has most of the
    # nodes (a frame that held a whole app), a map is made again from the entries that stay:
    # one walk, not one removal for each node.
    most? = 2 * length(ids) > map_size(s.nodes)
    gone? = fn k -> match?(%{^k => %{doc: ^doc}}, s.nodes) end

    drop = fn
      map, extra when most? -> :maps.filter(fn k, _ -> not gone?.(k) and k not in extra end, map)
      map, extra -> Map.drop(map, extra ++ ids)
    end

    put_st(%{
      s
      | nodes:
          if(most?,
            do: :maps.filter(fn _, n -> not match?(%{doc: ^doc}, n) end, s.nodes),
            else: Map.drop(s.nodes, ids)
          ),
        ids: id_index,
        aidx: aidx,
        iframes: :maps.filter(fn e, _ -> not gone?.(e) end, s.iframes),
        wrappers: drop.(s.wrappers, dead_aux),
        listeners: drop.(s.listeners, [{:window, doc}]),
        realms: realms,
        frames: frames,
        meta: Map.delete(s.meta, doc),
        fdirty: MapSet.delete(s.fdirty, doc),
        rev: s.rev + 1
    })

    :ok
  end

  # the document of the frame that the host object `data` of a window, a location, a history
  # or a storage belongs to; nil for the page's own and for other data
  defp aux_doc({:window, d}), do: d
  defp aux_doc({:location, d}), do: d
  defp aux_doc({:history, d}), do: d
  defp aux_doc({:storage, _, d}), do: d
  defp aux_doc(_), do: nil

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

  defp split_realm({:style, nid, :computed} = data) when is_integer(nid) do
    case st().nodes do
      %{^nid => n} -> {n.doc, data}
      _ -> {nil, data}
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

  # the root a node is in the document's tree through: past a shadow root to its host
  defp root_of(nid), do: root_in(st().nodes, nid)

  # (one read of the node table for the whole walk; a node that is gone reads as a
  # detached node, as `node/1` gives it)
  defp root_in(nodes, nid) do
    case nodes do
      %{^nid => %{parent: nil, shost: nil}} -> nid
      %{^nid => %{parent: nil, shost: h}} -> root_in(nodes, h)
      %{^nid => %{parent: p}} -> root_in(nodes, p)
      _ -> nid
    end
  end

  # the top of the tree the node is in (a shadow root is the top of its own tree)
  defp top_of(nid) do
    case node(nid).parent do
      nil -> nid
      p -> top_of(p)
    end
  end

  defp realm_key_to_doc(:window), do: st().main
  defp realm_key_to_doc({:window, d}), do: d
  defp realm_key_to_doc({:objt, _}), do: nil
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
      ids: %{},
      aidx: %{},
      iframes: %{},
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
      # the form control that has focus (a node id)
      focus_ctl: nil,
      ed_sel: nil,
      scroll: {0.0, 0.0},
      content: {0.0, 0.0},
      next_nid: Browser.Nids.max_nid(raw, -1) + 1,
      # each tag that an element of the node table has had (see `tag_absent?/2`)
      tags: %{}
    })

    doc = new_node(%{kind: :document})
    s = st()
    put_st(%{s | doc: doc, main: doc})
    kids = build_all(raw, doc)
    update_node_quiet(doc, &%{&1 | kids: kids, doc: doc})
    clean()
    doc
  end

  defp update_node_quiet(nid, fun), do: put_st(quiet_in(st(), nid, fun))

  # `update_node_quiet/2` on a state that the caller holds
  defp quiet_in(s, nid, fun) do
    old = node_in(s.nodes, nid)
    n = with_classes(fun.(old))

    s = reindex_all(s, nid, old, n)
    %{s | nodes: Map.put(s.nodes, nid, n), rev: s.rev + 1}
  end

  # what the browser itself puts on elements; any other name starting with `@` is the page's
  # own (Vue's `@click`, Lit's `@change$lit$`)
  @internal_attrs ~w(@cid @nid @znid @z @computed @content @marker @placeholder @src @summary @canvas
                     @sized @float @flex_sized @definite @ed @edhost @t)

  # The nodes of the parsed trees `raws`, with `parent` as their parent: gives their ids. All
  # the nodes are made on one state (`build_in/3`), which is read and written one time. The ids,
  # the indexes and the counts are the same as when each node is made with `new_node/1`.
  defp build_all(raws, parent) do
    {ids, s} = build_list(st(), raws, parent)
    put_st(s)
    ids
  end

  defp build_list(s, raws, parent),
    do: Enum.map_reduce(raws, s, fn raw, s -> build_in(s, raw, parent) end)

  defp build_in(s, {:text, t}, parent),
    do: put_new(s, %{blank_node(s.next, s.doc) | kind: :text, text: t, parent: parent})

  defp build_in(s, {:comment, t}, parent),
    do: put_new(s, %{blank_node(s.next, s.doc) | kind: :comment, text: t, parent: parent})

  defp build_in(s, {:element, tag, attrs, kids}, parent) do
    {internal, visible} = Enum.split_with(attrs, fn {k, _} -> k in @internal_attrs end)

    n = %{
      blank_node(s.next, s.doc)
      | tag: tag,
        attrs: visible,
        internal: internal,
        parent: parent
    }

    if tag == "template" do
      {nid, s} = put_new(s, n)
      {kid_ids, s} = build_list(s, kids, nid)
      # what is inside a template is its content: a fragment of its own, not part of the page
      {frag, s} = add_node(s, %{kind: :fragment})
      s = :lists.foldl(fn k, s -> quiet_in(s, k, &%{&1 | parent: frag}) end, s, kid_ids)
      s = quiet_in(s, frag, &%{&1 | kids: kid_ids})
      {nid, quiet_in(s, nid, &%{&1 | content: frag})}
    else
      # (the element goes in the node table one time, with its kids: `rev` counts the write
      # of the kids as `quiet_in/3` does)
      {n, s} = index_node(s, n)
      {kid_ids, s} = build_list(s, kids, n.id)
      {n.id, %{s | nodes: Map.put(s.nodes, n.id, %{n | kids: kid_ids}), rev: s.rev + 1}}
    end
  end

  defp put_new(s, n) do
    {n, s} = index_node(s, n)
    {n.id, %{s | nodes: Map.put(s.nodes, n.id, n)}}
  end

  # `build_list/3` for a parsed tree with no `<template>` (`innerHTML` of a list). The result
  # is the same: the same ids, nodes, indexes and counts. But the large state map and the
  # large node table are not written for each node. The fields that change are kept in a
  # small tuple, the new nodes go into a list, and at the end one merge puts them into the
  # node table. This makes less garbage for each node.
  defp build_list_fast(s, raws, parent) do
    acc = {s.next, s.rev, s.ids, s.aidx, s.iframes, s.doc, []}
    {ids, {next, rev, ids_idx, aidx, iframes, _doc, new}} = fast_list(raws, parent, acc)

    s = %{
      s
      | next: next,
        rev: rev,
        ids: ids_idx,
        aidx: aidx,
        iframes: iframes,
        nodes: :maps.merge(s.nodes, :maps.from_list(new))
    }

    {ids, :lists.foldl(fn {_, n}, s -> add_tag(s, n) end, s, new)}
  end

  defp fast_list(raws, parent, acc), do: Enum.map_reduce(raws, acc, &fast_node(&1, parent, &2))

  defp fast_node({:text, t}, parent, {next, rev, ids, aidx, ifr, doc, new}) do
    n = %{blank_node(next, doc) | kind: :text, text: t, parent: parent}
    {next, {next + 1, rev + 1, ids, aidx, ifr, doc, [{next, n} | new]}}
  end

  defp fast_node({:comment, t}, parent, {next, rev, ids, aidx, ifr, doc, new}) do
    n = %{blank_node(next, doc) | kind: :comment, text: t, parent: parent}
    {next, {next + 1, rev + 1, ids, aidx, ifr, doc, [{next, n} | new]}}
  end

  defp fast_node({:element, tag, attrs, kids}, parent, {id, rev, ids, aidx, ifr, doc, new}) do
    # (the names of `@internal_attrs` start with `@`; most elements have none)
    {internal, visible} =
      if Enum.any?(attrs, &match?({"@" <> _, _}, &1)),
        do: Enum.split_with(attrs, fn {k, _} -> k in @internal_attrs end),
        else: {[], attrs}

    n = %{blank_node(id, doc) | tag: tag, attrs: visible, internal: internal, parent: parent}

    # (as `index_node/2`)
    ifr =
      if tag == "iframe" do
        Process.put(:dom_has_iframe, true)
        Map.put(ifr, id, true)
      else
        ifr
      end

    n = with_classes(n)
    ids = reindex(ids, id, nil, n)
    aidx = reindex_attrs(aidx, id, nil, n)

    {kid_ids, {next, rev, ids, aidx, ifr, doc, new}} =
      fast_list(kids, id, {id + 1, rev + 1, ids, aidx, ifr, doc, new})

    {id, {next, rev + 1, ids, aidx, ifr, doc, [{id, %{n | kids: kid_ids}} | new]}}
  end

  defp has_template?(raws) when is_list(raws), do: Enum.any?(raws, &has_template?/1)
  defp has_template?({:element, "template", _, _}), do: true
  defp has_template?({:element, _, _, kids}), do: has_template?(kids)
  defp has_template?(_), do: false

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
    # `:focus` is the control the window has focused, by control id
    {focus, controls} = Map.pop(controls, :focus, :keep)
    if focus != :keep, do: put_st(%{st() | focus_ctl: focus && control_node(focus)})

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

      # the controls of a frame's document are numbered with the page's
      case tag == "iframe" && Map.get(st().frames, nid) do
        doc when is_integer(doc) -> sync_kids(node(doc).kids, kids)
        _ -> :ok
      end
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
        attrs = export_attrs(n) ++ [{"@nid", ensure_nid(nid)}] ++ modal_attr(n) ++ shadow_attr(n)

        attrs =
          if inner != nil and edit_attr(n) == true, do: attrs ++ [{"@edhost", 1}], else: attrs

        {:element, n.tag, attrs, export_kids(n, inner)} |> with_frame(nid)
    end
  end

  # An `<iframe>` that holds a document takes the content of that document as its children, marked
  # with the frame's number and address: the frame's sheets apply inside it only, and its relative
  # addresses resolve against its own.
  defp with_frame({:element, "iframe", attrs, _} = el, nid) do
    case Map.get(st().frames, nid) do
      nil ->
        el

      doc ->
        # (the realm that is running is not in `realms`: its fields are the state's own)
        url = if doc == st().doc, do: st().url, else: get_in(st().realms, [doc, :fields, :url])

        docs = Process.get(:dom_export_frames)

        kids =
          if is_list(docs) and doc not in docs, do: [], else: Enum.map(node(doc).kids, &export/1)

        marks =
          [{"data-b-frame", Integer.to_string(doc)}] ++
            if(is_binary(url), do: [{"data-b-base", url}], else: [])

        {:element, "iframe", attrs ++ marks, kids}
    end
  end

  defp with_frame(el, _nid), do: el

  # `data-b-frame` with a scope of its own marks an element that has a shadow root (see
  # `Browser.Style.scoped_refs/1`); the shadow tree is styled by the sheets in it
  defp shadow_attr(%{shadow: root}) when root != nil, do: [{"data-b-frame", "s#{root}"}]
  defp shadow_attr(_), do: []

  defp attr_of(n, name) do
    case List.keyfind(n.attrs, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  # the children of `host` that its slot called `name` shows
  defp assigned(host, name) do
    Enum.filter(node(host).kids, fn k ->
      case node(k) do
        %{kind: :text} -> name == ""
        %{kind: :element} = e -> (attr_of(e, "slot") || "") == name
        _ -> false
      end
    end)
  end

  # a node of a host shown in a slot keeps the host's styles (see `Browser.CSS.context/8`)
  defp export_slotted(nid, root, host) do
    case export(nid, host) do
      {:element, tag, attrs, kids} ->
        {:element, tag, attrs ++ [{"data-b-slotted", "s#{root}"}], kids}

      other ->
        other
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

  # a dialog shown with `showModal()` (see `Browser.Modal`)
  defp modal_attr(n) do
    for key <- ["@modal", "@popover"], List.keymember?(n.internal, key, 0), do: {key, ""}
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

  # what the scripts drew on a canvas goes to the layout with the element
  defp export_attrs(%{tag: "canvas"} = n) do
    case Process.get({:canvas, n.id}) do
      %Browser.Canvas{w: w, h: h, ops: [_ | _]} = surface ->
        n.attrs ++ [{"@canvas", {w, h, Browser.Canvas.ops(surface)}}]

      _ ->
        n.attrs
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

  # a host shows its shadow tree, not its own children, which only a `<slot>` in it brings back
  defp export_kids(%{shadow: root}, host) when root != nil do
    adopted =
      case List.keyfind(node(root).internal, "@adopted", 0) do
        {_, texts} -> for t <- texts, do: {:element, "style", [], [{:text, t}]}
        nil -> []
      end

    adopted ++ Enum.map(node(root).kids, &export(&1, host))
  end

  defp export_kids(%{tag: "slot"} = n, host) do
    top = top_of(n.id)

    case node(top) do
      %{kind: :fragment, shost: h} when h != nil ->
        case assigned(h, attr_of(n, "name") || "") do
          [] -> export_plain_kids(n, host)
          nodes -> Enum.map(nodes, &export_slotted(&1, top, host))
        end

      _ ->
        export_plain_kids(n, host)
    end
  end

  defp export_kids(n, host), do: export_plain_kids(n, host)

  defp export_plain_kids(n, nil), do: Enum.map(n.kids, &export/1)

  defp export_plain_kids(n, host) do
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
        [if(pre?, do: n.text, else: Regex.replace(re(~r/[ \t\n\r\f]+/), n.text, " "))]

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
      v -> Str.downcase(v) in ["", "true", "plaintext-only"]
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
    # (the boxes of the frames' elements are in the same layout, in page coordinates)
    # (a layout made for the scripts knew elements that the page's layout, made from an older tree,
    # does not: they keep the boxes they have until the page's layout has them)
    rects = Map.merge(Process.get(:dom_forced_rects, %{}), rects)
    Process.put(:dom_page_rects, rects)
    put_st(%{st() | rects: rects, content: content})
    set_scroll(sx, sy)
  end

  @doc "The tab of the page was put behind another (or is shown again): the document hears `visibilitychange`."
  def set_hidden(hidden?) do
    if Process.get(:js_hidden, false) != hidden? do
      Process.put(:js_hidden, hidden?)
      dispatch(document(), "visibilitychange", %{bubbles: true, cancelable: false})
    end

    :ok
  end

  @doc """
  The window has another size: `innerWidth` and the like change, and the boxes a layout for the
  scripts made are the boxes of the old size, so the next question lays the page out again.
  """
  def set_viewport(w, h) do
    w = w * 1.0
    h = h * 1.0
    put_st(%{st() | width: w, height: h, rects: %{}})
    Enum.each([:dom_forced, :dom_forced_rects, :dom_page_rects], &Process.delete/1)

    for {name, v} <- [
          {"innerWidth", w},
          {"innerHeight", h},
          {"outerWidth", w},
          {"outerHeight", h}
        ],
        do: declare(global(), name, v)

    :ok
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
        case rect_of(id) do
          {x, y, w, h} -> frame_relative({x, y, w, h})
          nil -> inherited_rect(n.parent)
        end

      nil ->
        # (an element no layout was asked about has no number yet: laying out numbers it)
        with true <- layout_now(),
             {_, id} <- List.keyfind(node(nid).internal, "@nid", 0),
             %{^id => {x, y, w, h}} <- rects_here() do
          frame_relative({x, y, w, h})
        else
          _ -> inherited_rect(n.parent)
        end
    end
  end

  # the boxes the layout made: for a frame those of the page, whose coordinates are the page's
  defp rects_here do
    Process.get(:dom_page_rects) || st().rects
  end

  # the box of a numbered element. The page is laid out in the background, so a script that
  # made an element and asks for its size at once would find no box: then the page is laid
  # out now (see `layout_now/0`), when the host can do it.
  defp rect_of(id) do
    case rects_here() do
      %{^id => rect} ->
        rect

      _ ->
        layout_now() && Map.get(rects_here(), id)
    end
  end

  @layout_wait 5_000

  @doc "The time (ms) a script waits for a layout it asked for (see `layout_now/0`)."
  def layout_wait, do: @layout_wait

  # A layout for the scripts, made while they wait. It costs as much as the layout of the
  # page, so it is made only when the tree changed since the last one, and only while the
  # layouts made for the document so far have taken less than a few seconds and a third of the
  # time its scripts have run. (An element can have no box because it was asked for before its shadow
  # tree was made, so it cannot be told from one that is never drawn.)
  defp layout_now do
    info = Process.get(:rt_info, %{})
    rev = st().rev
    now = System.monotonic_time(:millisecond)
    {last, _last_end, _cost} = Process.get(:dom_forced, {nil, nil, 0})
    doc = st().doc
    {first_at, spent} = Map.get(Process.get(:dom_forced_spent, %{}), doc, {now, 0})

    allowed = spent <= 2_000 + div(now - first_at, 3)

    if info[:layout_now] && not Process.get(:js_hidden, false) && not laid_out?(last, rev, doc) &&
         allowed do
      chain = frame_chain(doc)
      Process.put(:dom_export_frames, chain)
      raw = Enum.map(node(st().main).kids, &export/1)
      Process.delete(:dom_export_frames)
      # (the export gives numbers to new elements, and this changes the rev. The layout is of
      # the tree after the export, so keep that rev: else the next miss lays out the same tree)
      rev = st().rev
      ref = make_ref()
      send(info.owner, {:layout_now, self(), ref, raw})

      result =
        receive do
          {:layout_now_done, ^ref, rects, content} -> {rects, content}
        after
          @layout_wait -> nil
        end

      done = System.monotonic_time(:millisecond)
      Process.put(:dom_forced, {{rev, chain}, done, done - now})

      Process.put(
        :dom_forced_spent,
        Map.put(Process.get(:dom_forced_spent, %{}), doc, {first_at, spent + done - now})
      )

      with {rects, content} <- result do
        # (the frames that were left out keep the boxes they had)
        rects = Map.merge(Process.get(:dom_page_rects, %{}), rects)
        Process.put(:dom_forced_rects, rects)
        Process.put(:dom_page_rects, rects)
        put_st(%{st() | rects: rects, content: content})
        true
      end
    end
  end

  # whether the last layout for the scripts is of the tree as it is now, with the frame of `doc`
  # in it (a layout for a frame leaves out the frames that are not on its chain: their new
  # elements get no numbers and no boxes there)
  defp laid_out?({rev, nil}, rev, _doc), do: true
  defp laid_out?({rev, chain}, rev, doc), do: doc in chain
  defp laid_out?(_last, _rev, _doc), do: false

  @doc """
  Asks the host to lay the page out as it is now, and does not wait for the answer: what the host
  works out about the page's style sheets and cascade (it keeps it for the layouts that follow) is
  then ready by the time a script asks where something is. A frame that has just been parsed calls
  this before its scripts run. The request has no reference (`nil`): no script reads its boxes.
  """
  def prewarm_layout do
    info = Process.get(:rt_info, %{})

    if info[:layout_now] && not Process.get(:js_hidden, false) do
      Process.delete(:dom_export_frames)
      raw = Enum.map(node(st().main).kids, &export/1)
      send(info.owner, {:layout_now, self(), nil, raw})
    end

    :ok
  end

  # the frames whose content a layout for the scripts of `doc` needs: the frame of `doc` and
  # the frames it is in. The other frames are left out, as they cost a lot to
  # send and to lay out. (The page itself: all of them.)
  defp frame_chain(doc) do
    if doc == st().main, do: nil, else: [doc | frame_parents(doc)]
  end

  defp frame_parents(doc) do
    case Map.get(st().meta, doc) do
      %{iframe: i} when i != nil ->
        up = node(i).doc
        if up == st().main, do: [], else: [up | frame_parents(up)]

      _ ->
        []
    end
  end

  # in a frame, a box is where it is in the frame: the page coordinates less the frame's corner
  defp frame_relative(rect) do
    with false <- st().doc == st().main,
         %{iframe: i} when i != nil <- Map.get(st().meta, st().doc),
         {_, id} <- List.keyfind(node(i).internal, "@nid", 0),
         %{^id => {fx, fy, _, _}} <- Process.get(:dom_page_rects, %{}) do
      {x, y, w, h} = rect
      {x - fx, y - fy, w, h}
    else
      _ -> rect
    end
  end

  # (a frame that was not laid out yet: its elements are as wide as the frame, with no height)
  defp inherited_rect(nil) do
    if st().doc == st().main,
      do: {0.0, 0.0, 0.0, 0.0},
      else: {0.0, 0.0, st().width * 1.0, st().height * 1.0}
  end

  defp inherited_rect(parent) do
    case page_rect(parent) do
      {x, y, w, _} -> {x, y, if(st().doc == st().main, do: 0.0, else: w), 0.0}
    end
  end

  defp scrolling_element?(n), do: n.kind == :document or n.tag in ["html", "body"]

  defp metric(n, key) do
    scroller = scrolling_element?(n)
    # (only a key that reads a box or the content size lays the page out)
    {x, y, w, h} = if box_metric?(key, scroller), do: page_rect(n.id), else: {0, 0, 0, 0}
    {sx, sy} = st().scroll
    {cw, ch} = st().content

    value =
      case {key, scroller} do
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

  defp box_metric?(key, _) when key in ["offsetWidth", "offsetHeight", "offsetTop", "offsetLeft"],
    do: true

  defp box_metric?(key, true), do: key in ["scrollHeight", "scrollWidth"]

  defp box_metric?(key, false),
    do: key in ["clientWidth", "clientHeight", "scrollWidth", "scrollHeight"]

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
  def descendants(nid),
    do: nid |> node() |> Map.fetch!(:kids) |> walk_kids([]) |> :lists.reverse()

  # pre-order, newest first
  defp walk_kids([], acc), do: acc
  defp walk_kids([k | rest], acc), do: walk_kids(rest, walk_kids(node(k).kids, [k | acc]))

  @doc "True when the node is inside a `<template>` (its content is inert: no script in it runs)."
  def in_template?(nid) do
    Enum.any?(ancestors(nid), fn a -> node(a).kind == :element and node(a).tag == "template" end)
  end

  defp elements(nid), do: elements_tagged(nid, nil)

  # The elements below `nid` in document order, with the tag `tag` (nil: all). The node table
  # is read one time for the walk.
  defp elements_tagged(nid, tag) do
    nodes = st().nodes
    walk_in(nodes, node_in(nodes, nid).kids, tag, []) |> :lists.reverse()
  end

  defp walk_in(_nodes, [], _tag, acc), do: acc

  defp walk_in(nodes, [k | rest], tag, acc) do
    n = node_in(nodes, k)
    acc = if n.kind == :element and (tag == nil or n.tag == tag), do: [k | acc], else: acc
    walk_in(nodes, rest, tag, walk_in(nodes, n.kids, tag, acc))
  end

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

  # The element with the id `id` that comes first in tree order below `root` (a document, a
  # fragment, a shadow root or an element). The index of the ids (`st().ids`) gives the
  # elements with that id in all trees. When only one element has the id, the search does not
  # walk the tree: the element is the answer when it is below `root`. The writes to the node
  # table keep the index exact, and a node that leaves a tree keeps its id but gets a new
  # top, so it is not below `root` any more. When more elements have the id, the search walks
  # the tree as before. The index keeps the nodes that left their trees too, so the list of an
  # id that a page makes again and again has no limit, and a walk stops at the first match.
  # The index has no empty id, so an empty id walks the tree too.
  defp element_by_id(root, ""), do: find_element(root, &(get_attr(&1, "id") == ""))

  defp element_by_id(root, id) do
    case st().ids do
      %{^id => [nid]} -> if below?(nid, root), do: nid
      %{^id => _} -> find_element(root, &(get_attr(&1, "id") == id))
      _ -> nil
    end
  end

  # True when `root` is an ancestor of `nid` through the parent links (a shadow root and the
  # content of a template are tops of their own trees, as in `find_element/2`).
  defp below?(nid, root) do
    case st().nodes do
      %{^nid => %{parent: ^root}} -> true
      %{^nid => %{parent: nil}} -> false
      %{^nid => %{parent: p}} -> below?(p, root)
      _ -> false
    end
  end

  @doc "The node id of the n-th `<form>` (the number the page's form index uses), or nil."
  def form_node(fid), do: Enum.at(Enum.filter(elements(st().doc), &(node(&1).tag == "form")), fid)

  # the number the page's form index uses for a `<form>`
  defp form_index(nid) do
    Enum.find_index(Enum.filter(elements(st().doc), &(node(&1).tag == "form")), &(&1 == nid))
  end

  @doc "Calls the page-global function `name` (a hook the prelude defines), if there is one."
  def call_global(name, args) do
    case deref_global(name) do
      f when is_tuple(f) -> if function?(f), do: call(f, :undefined, args), else: :ok
      _ -> :ok
    end
  end

  @doc "What a click that no script stopped does to popovers: the button's target, light dismiss."
  def popover_click(target) do
    nid =
      case target do
        {:control, cid} -> control_node(cid)
        {:numbered, n} -> nid_numbered(n)
        _ -> nil
      end

    call_global("__popoverClick", [if(nid, do: wrap(nid), else: :null)])
  end

  @doc "The controls in the form numbered `fid` go back to the values their markup gives."
  def reset_form(fid) do
    case form_node(fid) do
      nil -> :ok
      nid -> reset_controls(nid)
    end
  end

  # the same for the form with element number `nid`
  def reset_controls(nid) do
    for el <- elements(nid), node(el).tag in ["input", "textarea", "select", "option"] do
      update_node(el, fn n ->
        %{n | props: Map.drop(n.props, ["value", "checked", "selectedIndex", "selected"])}
      end)
    end

    :ok
  end

  @doc "A click on the backdrop of the dialog whose number, made negative, is `n`."
  def dialog_backdrop(n) do
    case nid_numbered(n) do
      nil -> :ok
      nid -> call_global("__dialogBackdrop", [wrap(nid)])
    end
  end

  @doc "`<form method=dialog>` number `fid` was submitted by the control `cid` (nil: by script)."
  def dialog_submit(fid, cid) do
    case form_node(fid) do
      nil ->
        :ok

      form when is_integer(form) ->
        if Str.downcase(get_attr(node(form), "method") || "") != "dialog" and
             not formmethod_dialog?(cid),
           do: :ok,
           else: do_dialog_submit(form, cid)
    end
  end

  defp formmethod_dialog?(nil), do: false

  defp formmethod_dialog?(cid) do
    case control_node(cid) do
      nil -> false
      nid -> Str.downcase(get_attr(node(nid), "formmethod") || "") == "dialog"
    end
  end

  defp do_dialog_submit(form, cid) do
    case form do
      nil ->
        :ok

      form ->
        submitter = cid && control_node(cid)

        call_global("__dialogSubmit", [
          wrap(form),
          if(submitter, do: wrap(submitter), else: :null)
        ])
    end
  end

  @doc "The node id of the element for the page's control `cid`, or nil."
  def control_node(cid) do
    # (the controls of the frames are numbered with the page's)
    Enum.find_value(realm_docs(), fn doc ->
      Enum.find(elements(doc), fn nid ->
        List.keyfind(node(nid).internal, "@cid", 0) == {"@cid", cid}
      end)
    end)
  end

  @doc "The element of the page's control `cid` (nil: none) as a JS value, or null."
  def control_object(cid), do: wrap_or_null(cid && control_node(cid))

  def get_attr(n, name), do: with({_, v} <- List.keyfind(n.attrs, name, 0), do: v)

  defp attr_or(n, name, default), do: get_attr(n, name) || default

  defp text_content(nid) do
    n = node(nid)

    case n.kind do
      k when k in [:text, :comment] -> n.text
      _ -> n.kids |> Enum.reject(&(node(&1).kind == :comment)) |> Enum.map_join(&text_content/1)
    end
  end

  # a node of a frame that was removed is gone from the map; it has no ancestors
  defp ancestors(nid) do
    case st().nodes do
      %{^nid => %{parent: nil}} -> []
      %{^nid => %{parent: p}} -> [p | ancestors(p)]
      _ -> []
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
        insert_all(parent, node(child).kids, ref)

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
    s = st()

    if frame_below?(s, nid) do
      for k <- node(nid).kids do
        frames_leaving(k)
        update_node(k, &%{&1 | parent: nil})
      end
    else
      # (with no `<iframe>` below `nid`, `frames_leaving/1` has nothing to do: one pass)
      kids = node_in(s.nodes, nid).kids
      put_st(:lists.foldl(&put_node_in(&2, %{node_in(&2.nodes, &1) | parent: nil}), s, kids))
    end

    update_node(nid, &%{&1 | kids: []})
    insert_all(nid, kid_ids, nil)
  end

  # Puts the nodes `ids` into `parent` before `ref` (nil: at the end), as `insert/3` of each
  # node in turn. When `ids` are all the kids of a fragment (as `innerHTML` and
  # `insertAdjacentHTML` make), and the moves can not load a frame, upgrade a custom element
  # or move a node into another document, `move_kids/4` makes all the moves in one pass.
  # Then a long list does not read and write the state for each node, and the list of the
  # kids of `parent` is not copied again for each node.
  defp insert_all(parent, ids, ref) do
    case move_from(st(), parent, ids, ref) do
      nil -> Enum.each(ids, &insert(parent, &1, ref))
      frag -> move_kids(frag, parent, ids, ref)
    end
  end

  # The fragment whose kids are `ids`, when `insert_all/3` can move them in one pass; else nil.
  # For each node, `insert/3` then does not throw (the fragment is not `parent` and not above
  # it), `adopt/2` has nothing to do (the node has the document of `parent`), and `connect/1`
  # has nothing to do (no `<iframe>` is below the fragment, and no custom element can be
  # upgraded or connected).
  defp move_from(_s, _parent, [], _ref), do: nil

  defp move_from(s, parent, [k | _] = ids, ref) do
    nodes = s.nodes

    with %{^k => %{parent: frag}} when frag != nil <- nodes,
         %{^frag => %{kind: :fragment, kids: ^ids}, ^parent => %{doc: doc}} <- nodes,
         true <- ref == nil or not match?(%{^ref => %{parent: ^frag}}, nodes),
         true <- Enum.all?(ids, fn k -> match?(%{^k => %{doc: ^doc}}, nodes) end),
         false <- frag == parent or frag in ancestors(parent),
         false <- frame_below?(s, frag),
         true <- s.ce == %{} or not connected?(parent) do
      frag
    else
      _ -> nil
    end
  end

  # True when an `<iframe>` is below `nid` (see `below?/2`). A page has few of them.
  defp frame_below?(s, nid),
    do: map_size(s.iframes) > 0 and Enum.any?(Map.keys(s.iframes), &below?(&1, nid))

  # The moves of `insert_all/3` in one pass. The result is the same as `insert/3` of each node:
  # the node leaves the fragment and goes into `parent`, with the same count of writes (the
  # fragment, the node two times and `parent`: `rev`). Its attributes do not change, and it
  # has a parent before and after, so the indexes do not change.
  defp move_kids(frag, parent, ids, ref) do
    s = st()
    p = with_classes(Map.fetch!(s.nodes, parent))
    f = Map.fetch!(s.nodes, frag)

    kids =
      case ref && Enum.find_index(p.kids, &(&1 == ref)) do
        nil ->
          p.kids ++ ids

        i ->
          {before, rest} = Enum.split(p.kids, i)
          before ++ ids ++ rest
      end

    # (one merge writes the large table one time, in place of a write for each node)
    nodes =
      :maps.merge(
        s.nodes,
        :maps.from_list(for k <- ids, do: {k, %{Map.fetch!(s.nodes, k) | parent: parent}})
      )

    nodes = %{nodes | frag => %{f | kids: []}, parent => %{p | kids: kids}}
    s = %{s | nodes: nodes, rev: s.rev + 4 * length(ids)}
    put_st(s |> changed(f.doc) |> changed(p.doc))
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

  # The nodes of `html` as the kids of a new fragment: gives their ids. The nodes are made with
  # the fragment as their parent, in one pass (`build_list_fast/3`, or `build_list/3` when the
  # HTML has a `<template>`). The result is the same as `insert/3` of each new node into the
  # fragment: two writes for each node (`rev`), and nothing else to do for a fragment that is
  # not in a document.
  defp parse_fragment(html) do
    frag = new_node(%{kind: :fragment})
    raws = Browser.HTML.parse(html, comments: true)

    {ids, s} =
      if has_template?(raws),
        do: build_list(st(), raws, frag),
        else: build_list_fast(st(), raws, frag)

    f = Map.fetch!(s.nodes, frag)
    s = %{s | nodes: Map.put(s.nodes, frag, %{f | kids: ids}), rev: s.rev + 2 * length(ids)}
    put_st(if ids == [], do: s, else: changed(s, f.doc))
    ids
  end

  defp set_attr(nid, name, value) do
    name = Str.downcase(name)
    old_value = nid |> node() |> get_attr(name)
    was_open = name == "open" and open_of(node(nid))
    set_attr_quiet(nid, name, value)
    if name == "open", do: details_toggled(nid, was_open)
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
    name = Str.downcase(name)

    # a dialog that is not open is not modal any more
    if name == "open" and List.keymember?(node(nid).internal, "@modal", 0),
      do: out({:modal, :close})

    was_open = name == "open" and open_of(node(nid))

    update_node(nid, fn n ->
      n = %{n | attrs: List.keydelete(n.attrs, name, 0)}
      if name == "open", do: %{n | internal: List.keydelete(n.internal, "@modal", 0)}, else: n
    end)

    if name == "open", do: details_toggled(nid, was_open)
  end

  # A `<details>` that opened or closed (it was open when `was_open`) queues its `toggle` event
  # (see `__detailsToggle` in `Browser.JS.WebAPI`).
  defp details_toggled(nid, was_open) do
    n = node(nid)
    open = open_of(n)
    state = fn o -> if o, do: "open", else: "closed" end

    if n.tag == "details" and open != was_open,
      do: call_global("__detailsToggle", [wrap(nid), state.(was_open), state.(open)])

    :ok
  end

  # ── wrappers ───────────────────────────────────────────────

  @doc "The JavaScript object for a node (the same object every time)."
  def wrap(nid) do
    s = st()

    case s.wrappers do
      %{^nid => w} ->
        w

      _ ->
        w = new_host(__MODULE__, nid, wrapper_proto(node(nid)))
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

  # (a direct walk of the argument list: `Enum.at/3` slices the list, four calls and a list
  # for each argument)
  defp arg([a | _], 0), do: a
  defp arg([_ | rest], i), do: arg(rest, i - 1)
  defp arg([], _i), do: :undefined
  defp float(n), do: n * 1.0
  defp nodes_array(ids), do: new_array(wrap_all(ids))

  # `wrap/1` of each node of `ids`: the state is read and written one time for the list
  defp wrap_all(ids) do
    s = st()

    {ws, wrappers} =
      Enum.map_reduce(ids, s.wrappers, fn nid, wrappers ->
        case wrappers do
          %{^nid => w} ->
            {w, wrappers}

          _ ->
            w = new_host(__MODULE__, nid, wrapper_proto(node_in(s.nodes, nid)))
            {w, Map.put(wrappers, nid, w)}
        end
      end)

    if wrappers != s.wrappers, do: put_st(%{st() | wrappers: wrappers})
    ws
  end

  defp wrapper_proto(n) do
    case n.kind do
      :text -> proto({:dom, :text})
      :comment -> proto({:dom, :text})
      :document -> proto({:dom, :document})
      :fragment -> proto({:dom, :node})
      :element -> proto({:dom, {:tag, n.tag}}) || proto({:dom, :element})
    end
  end

  # ── host protocol: reads ───────────────────────────────────

  # The reads of a node that do not use the state of a realm: they read the node table and
  # make wrappers, and the prototypes of the wrappers are the same in all realms. A script of
  # the page that runs code of a frame reads them very often (a canvas of the frame gives its
  # size to each drawing call), so they do not swap the realm. A read of a document uses its
  # realm (`document.body` is the body of the running document), so it is not in the list.
  @realm_free_reads ~w(nodeType nodeName parentNode parentElement childNodes firstChild lastChild
                       nextSibling previousSibling nextElementSibling previousElementSibling
                       firstElementChild lastElementChild children childElementCount nodeValue
                       data length isConnected ownerDocument textContent tagName localName id
                       className classList style dataset value checked)

  # True when the read `key` of the node `n` does not use the state of a realm
  defp realm_free?(%{kind: kind}, key) when key in @realm_free_reads, do: kind != :document

  defp realm_free?(%{kind: :element, tag: "canvas"}, key) when key in ["width", "height"],
    do: true

  defp realm_free?(_n, _key), do: false

  @doc false
  # A read of a node is the most frequent read (jQuery reads `nodeType` and its data key of
  # each element of a list). The node is read from the table one time, and the realm changes
  # only when the node is in the document of an other realm (`in_realm/2` does nothing for
  # the running document and for a document that is not a realm).
  def host_get(nid, key, self) when is_integer(nid) do
    s = st()

    case s.nodes do
      %{^nid => n} ->
        doc = n.doc

        if doc == s.doc or not is_map_key(s.realms, doc) or realm_free?(n, key),
          do: node_get(n, key, self),
          else: in_realm(doc, fn -> hget(nid, key, self) end)

      _ ->
        hget(nid, key, self)
    end
  end

  # (the other host objects: a list of classes, a style, the window, ...)
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
  defp hget({:style, nid, :computed}, key, _self), do: computed_get(nid, key)
  defp hget({:dataset, nid}, key, _self), do: dataset_get(nid, key)
  # (a property that `defineProperty` put on the window itself comes before a variable of the
  # same name: a `let` binding stays as it is, see `Browser.JS.Global.define_var/2`)
  defp hget(:window, key, {:obj, id}) when is_binary(key) do
    if Obj.has_own?(deref(id), key), do: :miss, else: window_get(key)
  end

  defp hget(:window, key, _self), do: window_get(key)
  defp hget(:location, key, _self), do: location_get(key)
  defp hget({:usp, k}, key, _self), do: usp_get(k, key)
  defp hget({:storage, area}, key, _self), do: storage_get(area, key)

  defp hget(:history, "length", _self),
    do: {:ok, float(st().history_before + length(st().hist))}

  defp hget(:history, "state", _self), do: {:ok, hist_state()}
  defp hget(:history, "scrollRestoration", _self), do: {:ok, st().scroll_restoration}
  defp hget(_other, _key, _self), do: :miss

  # the event handler properties an element has (`"onclick" in el`; `el.onclick` is null)
  @on_events ~w(click dblclick auxclick mousedown mouseup mousemove mouseover mouseout mouseenter
                mouseleave keydown keyup keypress input change submit reset focus blur focusin
                focusout select scroll wheel contextmenu touchstart touchend touchmove touchcancel
                pointerdown pointerup pointermove pointerover pointerout pointerenter pointerleave
                pointercancel gotpointercapture lostpointercapture drag dragstart dragend dragover
                dragenter dragleave drop copy cut paste load error abort cancel close toggle
                beforeinput compositionstart compositionend compositionupdate animationstart
                animationend animationiteration transitionend transitionstart transitionrun
                transitioncancel resize invalid play pause ended canplay loadeddata loadedmetadata
                timeupdate volumechange seeking seeked readystatechange visibilitychange
                fullscreenchange selectionchange beforecopy beforecut beforepaste search selectstart
                securitypolicyviolation slotchange)

  defp node_get(n, key, self) do
    case {key, n.kind} do
      {"on" <> ev, k} when k in [:element, :document] and ev in @on_events ->
        handler =
          case Enum.find(Map.get(st().listeners, n.id, []), &(&1.type == ev and &1[:inline])) do
            %{fun: f} ->
              f

            nil ->
              with code when is_binary(code) <- if(k == :element, do: get_attr(n, key)),
                   f when is_tuple(f) <- inline_function(n.id, ev, code) do
                f
              else
                _ -> :null
              end
          end

        {:ok, handler}

      {"nodeType", k} ->
        {:ok, float(%{element: 1, text: 3, comment: 8, document: 9, fragment: 11}[k])}

      {"nodeName", :element} ->
        {:ok, Str.upcase(n.tag)}

      {"nodeName", :text} ->
        {:ok, "#text"}

      {"nodeName", :comment} ->
        {:ok, "#comment"}

      {"nodeName", :document} ->
        {:ok, "#document"}

      {"nodeName", :fragment} ->
        {:ok, "#document-fragment"}

      {"innerHTML", :fragment} ->
        {:ok, serialize_kids(n.id)}

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
        {:ok, Str.upcase(n.tag)}

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
           v -> if Str.downcase(v) in ["", "true"], do: "true", else: Str.downcase(v)
         end}

      "isContentEditable" ->
        {:ok, editable?(n.id)}

      "value" ->
        {:ok, value_of(n)}

      "checked" ->
        {:ok, checked_of(n)}

      "open" ->
        {:ok, if(n.tag == "dialog", do: get_attr(n, "open") != nil, else: open_of(n))}

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
        # a NamedNodeMap also has each attribute under its name (jQuery 1.9 reads
        # `div.attributes["onfocusin"].expando`)
        for {{k, _}, a} <- Enum.zip(n.attrs, attrs), do: put_hidden(list, k, a)
        by_name = Map.new(Enum.zip(Enum.map(n.attrs, &elem(&1, 0)), attrs))

        put_hidden(
          list,
          "getNamedItem",
          native("getNamedItem", fn _this, args ->
            Map.get(by_name, Str.downcase(to_str(arg(args, 0))), :null)
          end)
        )

        put_hidden(
          list,
          "item",
          native("item", fn _this, args -> Enum.at(attrs, to_int(arg(args, 0)), :null) end)
        )

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

      k when k in ["width", "height"] and n.tag == "canvas" ->
        {:ok, canvas_size(n, k)}

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

  defp type_of(%{tag: "input"} = n), do: Str.downcase(attr_or(n, "type", "text"))
  defp type_of(%{tag: "button"} = n), do: Str.downcase(attr_or(n, "type", "submit"))
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
        {:ok, wrap_or_null(ed_focused() || ctl_focused() || find_tag(s.doc, "body"))}

      "designMode" ->
        {:ok, if(s.design_mode, do: "on", else: "off")}

      "hidden" ->
        {:ok, Process.get(:js_hidden, false)}

      "visibilityState" ->
        {:ok, if(Process.get(:js_hidden, false), do: "hidden", else: "visible")}

      _ ->
        :miss
    end
  end

  defp find_tag(nid, tag), do: find_element(nid, &(&1.tag == tag))

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
  # (a property that `defineProperty` put on the window itself follows its own attributes)
  defp hput(:window, key, v, {:obj, id}) when is_binary(key) do
    if Obj.has_own?(deref(id), key), do: :miss, else: window_put(key, v)
  end

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

      # (a shadow root is a fragment)
      {"innerHTML", :fragment} ->
        set_children(n.id, parse_fragment(to_str_or_empty(v)))
        :ok

      {"on" <> event, :document} ->
        set_inline_handler(n.id, event, if(function?(v), do: v))
        :ok

      {"cookie", :document} ->
        Browser.Cookies.set_from_script(st().url, to_str(v))
        :ok

      {"designMode", :document} ->
        put_st(%{st() | design_mode: Str.downcase(to_str(v)) == "on"})
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

      # (a negative size keeps the size the canvas has)
      k when k in ["width", "height"] and n.tag == "canvas" ->
        num = to_num_or_zero(v)
        num = if num >= 0, do: num, else: canvas_size(n, k)
        set_attr(nid, k, Integer.to_string(trunc(num)))
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
        set_checked(nid, truthy(v))

      "open" ->
        cond do
          node(nid).tag != "dialog" ->
            was_open = open_of(node(nid))
            update_node(nid, &%{&1 | props: Map.put(&1.props, "open", truthy(v))})
            details_toggled(nid, was_open)

          truthy(v) ->
            set_attr(nid, "open", "")

          true ->
            remove_attr(nid, "open")
        end

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
        insert_all(p, new_ids, ref)
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

  defp classes(nid), do: nid |> node() |> class_tokens()

  defp put_classes(nid, list) do
    set_attr(nid, "class", Enum.join(Enum.uniq(list), " "))
  end

  defp classlist_get(nid, "length"), do: {:ok, float(length(classes(nid)))}
  defp classlist_get(nid, "value"), do: {:ok, attr_or(node(nid), "class", "")}

  defp classlist_get(nid, key) when is_binary(key) do
    case Integer.parse(key) do
      {i, ""} when i >= 0 -> with c when is_binary(c) <- Enum.at(classes(nid), i), do: {:ok, c}
      _ -> :miss
    end
  end

  defp classlist_get(_nid, _), do: :miss

  defp style_decls(nid) do
    node(nid)
    |> attr_or("style", "")
    |> String.split(";")
    |> Enum.flat_map(fn d ->
      case String.split(d, ":", parts: 2) do
        [k, v] -> [{String.trim(k) |> Str.downcase(), String.trim(v)}]
        _ -> []
      end
    end)
  end

  defp put_style_decls(nid, decls) do
    css = Enum.map_join(decls, " ", fn {k, v} -> "#{k}: #{v};" end)
    if css == "", do: remove_attr(nid, "style"), else: set_attr(nid, "style", css)
  end

  defp kebab(name) do
    for(<<c <- name>>, into: "", do: if(c in ?A..?Z, do: <<?-, c + 32>>, else: <<c>>))
    |> then(fn k -> if String.starts_with?(k, "css-float"), do: "float", else: k end)
  end

  # `getComputedStyle(el)`: what the element declares itself, then the size it was laid out at
  # (a frame's elements as wide as the frame), then the browser's usual values
  @block_tags ~w(html body div p section article aside header footer main nav ul ol li dl dt dd h1 h2 h3 h4 h5 h6
                 form fieldset table pre blockquote figure figcaption address hr details summary dialog)

  defp computed_get(_nid, key) when not is_binary(key), do: :miss
  defp computed_get(_nid, "length"), do: {:ok, 0.0}

  defp computed_get(nid, key) do
    if key in ~w(setProperty getPropertyValue removeProperty item getPropertyPriority) do
      :miss
    else
      n = node(nid)
      prop = kebab(key)

      case List.keyfind(style_decls(nid), prop, 0) do
        {_, v} -> {:ok, v}
        nil -> {:ok, cascaded(n, prop) || computed_default(n, prop)}
      end
    end
  end

  @cascaded %{"display" => 0, "visibility" => 1, "position" => 2, "float" => 3, "overflow" => 4}

  # What the page's style sheets give the element, from the layout (`Browser.Nids.styles/1`): an
  # element the layout left out while its parent is in it is `display: none` (jQuery's `fadeIn`
  # shows nothing it takes to be visible already). nil: the initial value, or not known.
  defp cascaded(n, prop) do
    with i when i != nil <- Map.get(@cascaded, prop),
         {_, id} <- nid_entry(n.id),
         %{} = styles <- styles_of(id) do
      case styles do
        %{^id => values} ->
          elem(values, i)

        _ ->
          parent = n.parent && node(n.parent)

          parent_id =
            with %{internal: internal} <- parent,
                 {_, pid} <- List.keyfind(internal, "@nid", 0),
                 do: pid

          if prop == "display" and is_map_key(styles, parent_id), do: "none"
      end
    else
      _ -> nil
    end
  end

  # (an element the last layout did not style may be new: the page is laid out now, when the
  # tree changed since the last layout for the scripts)
  defp styles_of(id) do
    case Map.get(rects_here(), :styles) do
      %{^id => _} = styles ->
        styles

      _ ->
        layout_now()
        Map.get(rects_here(), :styles)
    end
  end

  # (an element no layout was asked about has no number yet: laying out numbers it)
  defp nid_entry(nid) do
    case List.keyfind(node(nid).internal, "@nid", 0) do
      nil ->
        layout_now()
        List.keyfind(node(nid).internal, "@nid", 0)

      entry ->
        entry
    end
  end

  defp computed_default(n, prop) do
    px = fn v -> "#{round(v)}px" end

    # (only the width and the height read the box, so only they lay the page out)
    case prop do
      "width" -> px.(elem(page_rect(n.id), 2))
      "height" -> px.(elem(page_rect(n.id), 3))
      "display" -> if(n.tag in @block_tags, do: "block", else: "inline")
      "position" -> "static"
      "visibility" -> "visible"
      "opacity" -> "1"
      "overflow" -> "visible"
      "float" -> "none"
      "z-index" -> "auto"
      "box-sizing" -> "content-box"
      "color" -> "rgb(0, 0, 0)"
      "background-color" -> "rgba(0, 0, 0, 0)"
      "font-size" -> "16px"
      "font-weight" -> "400"
      "line-height" -> "normal"
      "text-align" -> "start"
      "direction" -> "ltr"
      "cursor" -> "auto"
      "transform" -> "none"
      "pointer-events" -> "auto"
      "padding" <> _ -> "0px"
      "margin" <> _ -> "0px"
      "border" <> _ -> if String.ends_with?(prop, "width"), do: "0px", else: ""
      _ -> ""
    end
  end

  defp style_get(nid, "cssText"), do: {:ok, attr_or(node(nid), "style", "")}
  defp style_get(nid, "length"), do: {:ok, float(length(style_decls(nid)))}
  defp style_get(_nid, key) when not is_binary(key), do: :miss

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
  defp target_obj({:objt, id}), do: {:obj, id}
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

  # a pointer event also says where it is in the page and in the element it went to
  # (an event of a script says where it is when its constructor was given a position)
  defp pointer_coords(event, target, %{event: _}) do
    if truthy(Interp.get(event, "__pos")) do
      init = %{
        "clientX" => Interp.get(event, "clientX"),
        "clientY" => Interp.get(event, "clientY")
      }

      pointer_coords(event, target, init)
    end

    :ok
  end

  defp pointer_coords(event, target, init) do
    with cx when is_number(cx) <- Map.get(init, "clientX"),
         cy when is_number(cy) <- Map.get(init, "clientY"),
         true <- is_integer(target) do
      {sx, sy} = st().scroll
      {x, y, _, _} = page_rect(target)
      px = cx + sx
      py = cy + sy

      for {k, v} <- [{"pageX", px}, {"pageY", py}, {"offsetX", px - x}, {"offsetY", py - y}],
          not Map.has_key?(init, k),
          do: put(event, k, v * 1.0)
    end

    :ok
  end

  # `init` may also hold `:event` (an event object of a script, which is dispatched itself),
  # `:trusted` (false for an event that a script caused, as `click()`), `:class` (the event
  # interface, else the one of the type) and `:activate` (true for a click that a script
  # caused: it runs the activation behavior, see `activation_target/2`)
  defp do_dispatch(target, type, init) do
    bubbles = Map.get(init, :bubbles, true)
    event = event_for(target, type, init, bubbles)
    # (the dispatch flag: a script cannot dispatch this event again while it is in dispatch)
    put_hidden(event, "__dispatching", true)

    pointer_coords(event, target, init)

    path =
      case target do
        :window -> [:window]
        {:window, _} -> [target]
        {:objt, _} -> [target]
        nid -> nid |> tree_path(Map.get(init, :composed, true)) |> with_window()
      end

    # (the element whose activation behavior a click runs, and what it changed before)
    act =
      if type == "click" and Map.get(init, :activate, false), do: activation_target(path, bubbles)

    pre = if act, do: pre_activation(act)

    # capture: from the outermost down to the target's parent
    outer_first = path |> tl() |> Enum.reverse()
    # (for `composedPath()` while the event is in dispatch)
    Process.put({:dom_event_path, event}, path)

    try do
      catch_stop(fn ->
        Enum.each(outer_first, &fire(&1, event, :capture))
        fire(hd(path), event, :at_target)
        if bubbles, do: Enum.each(tl(path), &fire(&1, event, :bubble))
      end)
    after
      # (a script can keep the event and dispatch it again: the flags of this dispatch go)
      put(event, "currentTarget", :null)
      put(event, "eventPhase", 0.0)
      put_hidden(event, "__dispatching", false)
      Process.delete({:dom_event_path, event})

      if truthy(Interp.get(event, "__stop")) do
        put_hidden(event, "__stop", false)
        put_hidden(event, "__stop_immediate", false)
      end
    end

    prevented? = truthy(Interp.get(event, "defaultPrevented"))

    cond do
      act == nil -> :ok
      prevented? -> canceled_activation(act, pre)
      true -> activation(act, target, pre)
    end

    if prevented?, do: :prevented, else: :ok
  end

  # The event object: the one of the script (`init.event`), else a new one of the interface of
  # the type, with the defaults of its members
  defp event_for(target, _type, %{event: ev}, _bubbles) do
    if truthy(Interp.get(ev, "__dispatching")) do
      ctor = deref_global("DOMException")

      throw(
        {:js_error,
         construct(ctor, ["The event is already being dispatched.", "InvalidStateError"], ctor)}
      )
    end

    # (`dispatchEvent` sets `isTrusted` to false, also for an event that the browser fired)
    put(ev, "isTrusted", false)
    put(ev, "target", target_obj(target))
    put(ev, "currentTarget", :null)
    put(ev, "eventPhase", 0.0)
    ev
  end

  defp event_for(target, type, init, bubbles) do
    class = Map.get(init, :class) || event_class(type)
    trusted = Map.get(init, :trusted, true)

    base = [
      {"type", type},
      {"target", target_obj(target)},
      {"currentTarget", :null},
      {"defaultPrevented", false},
      {"bubbles", bubbles},
      {"cancelable", Map.get(init, :cancelable, true)},
      {"composed", Map.get(init, :composed, true)},
      {"eventPhase", 0.0},
      {"isTrusted", trusted},
      {"timeStamp", Browser.JS.Builtins.perf_now()}
    ]

    members = event_members(class, &default_member(&1, init, target, type, trusted))
    aliases = for {k, _} = a <- mouse_aliases(class, members), not Map.has_key?(init, k), do: a
    pairs = base ++ members ++ aliases
    keys = Enum.map(pairs, &elem(&1, 0))
    extra = for {k, v} <- init, is_binary(k), k not in keys, do: {k, v}

    new_object(pairs ++ extra, event_proto(class))
  end

  # a member the browser sets on an event it fires when `init` does not give it: the window
  # (`view`) and the click count of a press, release or click (`detail`)
  defp default_member(k, init, target, type, trusted) do
    case Map.fetch(init, k) do
      {:ok, v} ->
        v

      :error ->
        case k do
          "view" ->
            if is_tuple(target) and elem(target, 0) == :objt,
              do: :undefined,
              else: target_obj(window_of_target(target))

          "detail" when trusted and type in ["click", "mousedown", "mouseup"] ->
            1.0

          "detail" when trusted and type == "dblclick" ->
            2.0

          _ ->
            :undefined
        end
    end
  end

  defp window_of_target(nid) when is_integer(nid), do: window_key_of(nid)
  defp window_of_target(target), do: target

  # The window comes after the document. An event in a tree that is not in a document (an
  # element that is not connected, or a shadow tree for an event that is not composed) does not
  # go to the window.
  defp with_window(path) do
    root = List.last(path)
    if node(root).kind == :document, do: path ++ [window_key_of(root)], else: path
  end

  # the node and its ancestors; a composed event goes on from a shadow root to its host
  defp tree_path(nid, composed) do
    chain = [nid | ancestors(nid)]

    case node(List.last(chain)).shost do
      host when composed and host != nil -> chain ++ tree_path(host, composed)
      _ -> chain
    end
  end

  defp put(o, k, v), do: Interp.put(o, k, v)

  defp catch_stop(fun) do
    fun.()
    :done
  catch
    :dom_stop -> :stopped
  end

  defp fire(target, event, phase) do
    # (a script can stop the propagation before the dispatch: then no listener runs)
    if truthy(Interp.get(event, "__stop")), do: throw(:dom_stop)
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

  defp describe({:obj, _} = v),
    do: Interp.describe_error(v) || Browser.JS.Builtins.inspect_js(v, 0, [])

  defp describe(v), do: Browser.JS.Builtins.inspect_js(v, 0, [])

  defp console_error(text),
    do: Process.put(:js_console, [{:error, text} | Process.get(:js_console, [])])

  # ── selectors ──────────────────────────────────────────────

  # a selector list: [[{combinator, compound}, ...], ...], each selector rightmost first (the
  # order in which `match_parts/2` tests them). Scripts ask the same few selectors again and
  # again, so what was parsed is kept.
  defp parse_selectors(str) do
    memo({:sel, str}, fn ->
      str
      |> split_top(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_complex/1)
    end)
  end

  @memo_max 2_000

  defp memo(key, fun) do
    cache = :erlang.get(:js_memo)
    cache = if cache == :undefined, do: %{}, else: cache

    case cache do
      %{^key => v} ->
        v

      _ ->
        v = fun.()
        cache = if map_size(cache) >= @memo_max, do: %{}, else: cache
        :erlang.put(:js_memo, Map.put(cache, key, v))
        v
    end
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

  # (the parts come out rightmost first, the order in which `match_parts/2` tests them)
  defp build_complex([], _comb, acc), do: acc
  defp build_complex([{:comb, c} | rest], _comb, acc), do: build_complex(rest, c, acc)

  defp build_complex([{:compound, s} | rest], comb, acc),
    do: build_complex(rest, " ", [{comb, parse_compound(s)} | acc])

  defp parse_compound(s) do
    re(
      ~r/(\*|[a-zA-Z][\w-]*)|#([\w-]+)|\.([\w-]+)|\[([^\]]*)\]|:([\w-]+)(\((?:[^()]|\([^()]*\))*\))?/
    )
    |> Regex.scan(s)
    |> Enum.map(fn
      [_, tag] when tag != "" -> {:tag, Str.downcase(tag)}
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
           re(
             ~r/^\s*([\w:-]+)\s*(?:([~|^$*]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s\]]*))\s*(i)?)?\s*$/
           ),
           s
         ) do
      nil ->
        {s, nil, nil}

      [_, name] ->
        {Str.downcase(name), nil, nil}

      [_, name, op | vals] ->
        {Str.downcase(name), op, vals |> Enum.take(3) |> Enum.find("", &(&1 != ""))}
    end
  end

  defp matches?(nid, selectors), do: node_matches?(node(nid), selectors)

  # The tests below take the node, not its id, so that a walk of the tree reads each node
  # from the table one time only.
  defp node_matches?(%{kind: :element} = n, selectors), do: any_selector?(n, selectors)
  defp node_matches?(_n, _selectors), do: false

  defp any_selector?(_n, []), do: false
  defp any_selector?(n, [parts | more]), do: match_parts(n, parts) or any_selector?(n, more)

  # `parts` is rightmost first
  defp match_parts(n, [{_comb, compound}]), do: match_conds(n, compound)

  defp match_parts(n, [{comb, compound} | rest]) do
    match_conds(n, compound) and
      case comb do
        " " -> Enum.any?(ancestors(n.id), &match_element(&1, rest))
        ">" -> (p = parent_element(n.id)) != nil and match_parts(node(p), rest)
        "+" -> (s = sibling_elements(n.id, :prev)) != nil and match_parts(node(s), rest)
        "~" -> Enum.any?(prev_elements(n.id), &match_parts(node(&1), rest))
      end
  end

  defp match_element(nid, parts) do
    n = node(nid)
    n.kind == :element and match_parts(n, parts)
  end

  defp match_conds(_n, []), do: true
  defp match_conds(n, [c | more]), do: match_cond(n, c) and match_conds(n, more)

  defp prev_elements(nid) do
    {before, _} = siblings(nid)
    before |> Enum.filter(&(node(&1).kind == :element))
  end

  defp match_cond(n, {:tag, "*"}), do: n.kind == :element
  defp match_cond(n, {:tag, t}), do: n.tag == t
  defp match_cond(n, {:id, id}), do: get_attr(n, "id") == id
  defp match_cond(n, {:class, c}), do: c in class_tokens(n)

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

  defp match_cond(n, {:pseudo, "first-of-type", _}),
    do: List.first(same_type_kids(n)) == n.id

  defp match_cond(n, {:pseudo, "last-of-type", _}), do: List.last(same_type_kids(n)) == n.id
  defp match_cond(n, {:pseudo, "only-of-type", _}), do: same_type_kids(n) == [n.id]

  defp match_cond(n, {:pseudo, "nth-child", arg}), do: nth_match(n, arg, false, false)
  defp match_cond(n, {:pseudo, "nth-last-child", arg}), do: nth_match(n, arg, true, false)
  defp match_cond(n, {:pseudo, "nth-of-type", arg}), do: nth_match(n, arg, false, true)
  defp match_cond(n, {:pseudo, "nth-last-of-type", arg}), do: nth_match(n, arg, true, true)

  defp match_cond(n, {:pseudo, "has", arg}) when is_binary(arg) do
    arg
    |> split_top(",")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(fn rel ->
      {comb, rest} =
        case rel do
          <<c, r::binary>> when c in [?>, ?+, ?~] -> {<<c>>, String.trim(r)}
          _ -> {" ", rel}
        end

      sels = parse_selectors(rest)
      {_, after_sibs} = siblings(n.id)
      after_els = Enum.filter(after_sibs, &(node(&1).kind == :element))

      candidates =
        case comb do
          " " -> elements(n.id)
          ">" -> element_kids(n.id)
          "+" -> Enum.take(after_els, 1)
          "~" -> after_els
        end

      candidates =
        if comb in ["+", "~"],
          do: candidates ++ Enum.flat_map(candidates, &elements/1),
          else: candidates

      (comb in ["+", "~"] &&
         Enum.any?(
           Enum.take(after_els, if(comb == "+", do: 1, else: length(after_els))),
           &matches?(&1, sels)
         )) or
        (comb in [" ", ">"] and Enum.any?(candidates, &matches?(&1, sels)))
    end)
  end

  defp match_cond(n, {:pseudo, "link", _}),
    do: n.tag in ["a", "area"] and get_attr(n, "href") != nil

  defp match_cond(n, {:pseudo, "any-link", _}),
    do: n.tag in ["a", "area"] and get_attr(n, "href") != nil

  defp match_cond(n, {:pseudo, "required", _}), do: get_attr(n, "required") != nil
  defp match_cond(n, {:pseudo, "optional", _}), do: get_attr(n, "required") == nil

  defp match_cond(n, {:pseudo, "read-only", _}),
    do:
      not (n.tag in ["input", "textarea"] and get_attr(n, "readonly") == nil and
             get_attr(n, "disabled") == nil)

  defp match_cond(n, {:pseudo, "read-write", _}),
    do:
      n.tag in ["input", "textarea"] and get_attr(n, "readonly") == nil and
        get_attr(n, "disabled") == nil

  defp match_cond(n, {:pseudo, "defined", _}),
    do: not String.contains?(n.tag || "", "-") or registered(n.tag) != nil

  defp match_cond(_n, {:pseudo, "scope", _}), do: false
  defp match_cond(n, {:pseudo, "empty", _}), do: n.kids == []
  defp match_cond(n, {:pseudo, "checked", _}), do: checked_of(n) == true
  defp match_cond(n, {:pseudo, "disabled", _}), do: get_attr(n, "disabled") != nil
  defp match_cond(n, {:pseudo, "enabled", _}), do: get_attr(n, "disabled") == nil
  defp match_cond(n, {:pseudo, "root", _}), do: n.tag == "html"
  defp match_cond(n, {:pseudo, "modal", _}), do: List.keymember?(n.internal, "@modal", 0)
  defp match_cond(n, {:pseudo, "popover-open", _}), do: List.keymember?(n.internal, "@popover", 0)

  defp match_cond(n, {:pseudo, "open", _}),
    do: n.tag in ["dialog", "details"] and open_of(n) == true

  defp match_cond(n, {:pseudo, "not", arg}), do: not matches?(n.id, parse_selectors(arg))
  defp match_cond(n, {:pseudo, "is", arg}), do: matches?(n.id, parse_selectors(arg))
  defp match_cond(n, {:pseudo, "where", arg}), do: matches?(n.id, parse_selectors(arg))
  defp match_cond(_n, {:pseudo, _, _}), do: false
  defp match_cond(_n, _), do: false

  defp kid_elements(n), do: if(n.parent, do: element_kids(n.parent), else: [n.id])

  # the element children of the parent that have the element's tag
  defp same_type_kids(n) do
    Enum.filter(kid_elements(n), &(node(&1).tag == n.tag))
  end

  # `:nth-child(an+b)` and its kin: is the element at a position the formula gives?
  # `same_type?` counts only the siblings with the tag of the element (`:nth-of-type`).
  defp nth_match(n, arg, from_end?, same_type?) do
    {anb, of_sel} =
      memo({:nth, arg}, fn ->
        case String.split(arg || "", re(~r/\s+of\s+/), parts: 2) do
          [f, sel] -> {parse_anb(f), parse_selectors(sel)}
          [f] -> {parse_anb(f), nil}
        end
      end)

    index =
      if of_sel do
        kids = if same_type?, do: same_type_kids(n), else: kid_elements(n)
        kids = Enum.filter(kids, &matches?(&1, of_sel))
        kids = if from_end?, do: Enum.reverse(kids), else: kids
        Enum.find_index(kids, &(&1 == n.id))
      else
        sibling_index(n, from_end?, if(same_type?, do: n.tag, else: :any))
      end

    case index do
      nil ->
        false

      i ->
        case anb do
          {a, b} ->
            pos = i + 1

            if a == 0,
              do: pos == b,
              else: rem(pos - b, a) == 0 and div(pos - b, a) >= 0

          :error ->
            false
        end
    end
  end

  # The index of the element `n` among the element children of its parent that have the tag
  # `tag` (`:any`: all of them), from the end when `from_end?`, or nil: as the index of `n` in
  # `kid_elements/1` or `same_type_kids/1`. The walk stops at `n`. A query asks
  # `:nth-child(i)` of each candidate before the match, so a list of all the children for
  # each candidate made a query on a long list slow (Speedometer's jQuery suite).
  defp sibling_index(%{parent: nil}, _from_end?, _tag), do: 0
  defp sibling_index(%{kind: kind}, _from_end?, _tag) when kind != :element, do: nil

  defp sibling_index(n, from_end?, tag) do
    kids = node(n.parent).kids
    kids = if from_end?, do: Enum.reverse(kids), else: kids
    count_before(kids, n.id, tag, 0)
  end

  defp count_before([], _nid, _tag, _i), do: nil
  defp count_before([nid | _], nid, _tag, i), do: i

  defp count_before([k | rest], nid, tag, i) do
    case node(k) do
      %{kind: :element, tag: t} when tag == :any or t == tag ->
        count_before(rest, nid, tag, i + 1)

      _ ->
        count_before(rest, nid, tag, i)
    end
  end

  defp parse_anb(f) do
    f = f |> Str.downcase() |> String.replace(re(~r/\s+/), "")

    case f do
      "odd" ->
        {2, 1}

      "even" ->
        {2, 0}

      _ ->
        case Regex.run(re(~r/^([+-]?\d*)n([+-]\d+)?$/), f) do
          [_, a] ->
            {anb_coef(a), 0}

          [_, a, b] ->
            {anb_coef(a), String.to_integer(String.trim_leading(b, "+"))}

          nil ->
            case Integer.parse(f) do
              {b, ""} -> {0, b}
              _ -> :error
            end
        end
    end
  end

  defp anb_coef(a) when a in ["", "+"], do: 1
  defp anb_coef("-"), do: -1
  defp anb_coef(a), do: String.to_integer(String.trim_leading(a, "+"))

  defp attr_match(nil, _v, _), do: true
  defp attr_match("=", v, val), do: v == val
  defp attr_match("~=", v, val), do: val in split_words(v)
  defp attr_match("|=", v, val), do: v == val or String.starts_with?(v, val <> "-")
  defp attr_match("^=", v, val), do: val != "" and String.starts_with?(v, val)
  defp attr_match("$=", v, val), do: val != "" and String.ends_with?(v, val)
  defp attr_match("*=", v, val), do: val != "" and String.contains?(v, val)

  defp query_all(root, selector) do
    sels = parse_selectors(selector)

    if tag_absent?(st(), sels) do
      []
    else
      case candidates(sels, root) do
        :walk -> walk_matches(node(root).kids, st().nodes, sels, []) |> :lists.reverse()
        nids -> for nid <- nids, below?(nid, root), matches?(nid, sels), do: nid
      end
    end
  end

  # True when no element can match the selector list `sels`: each selector has a compound
  # with a tag that no element of the node table has (`querySelector("base")` on a page with
  # no `<base>`). Then a search gives nothing at once, with no walk of the tree. A compound
  # must match an element for the selector to match, so one such compound is enough. (Only
  # the tag of the compound itself counts, not one inside `:not()` or `:is()`.)
  defp tag_absent?(%{tags: tags}, sels),
    do: sels != [] and Enum.all?(sels, &complex_tag_absent?(&1, tags))

  defp tag_absent?(_s, _sels), do: false

  defp complex_tag_absent?(complex, tags) do
    Enum.any?(complex, fn {_comb, compound} ->
      Enum.any?(compound, fn
        {:tag, "*"} -> false
        {:tag, t} -> not is_map_key(tags, t)
        _ -> false
      end)
    end)
  end

  # The elements that can match a selector list, when an index gives them, or :walk. A
  # selector list with one selector whose last compound has an id (`#a`, `ul > li#a.b`) can
  # match only an element with that id. When at most one element has the id, the tree is not
  # walked. When more elements have it, the tree is walked, for the reason that
  # `element_by_id/2` gives. A last compound with no id but with `[name="v"]` can match only an
  # element with that value (see `attr_candidates/3`).
  defp candidates(sels, root) do
    case selector_key(sels) do
      nil ->
        :walk

      {:id, id} ->
        case st().ids do
          %{^id => [nid]} -> [nid]
          %{^id => _} -> :walk
          _ -> []
        end

      {:attr, name, v} ->
        case attr_index(name) do
          nil -> :walk
          %{^v => set} -> attr_candidates(set, root, sels)
          _ -> []
        end
    end
  end

  # The elements of `set` (the elements with the value) that are below `root` and match, when
  # there is at most one, or :walk. Two that match need a walk, which gives them in document
  # order. The set can have elements of other trees, and of trees that left the document (a
  # list item that the page drew again keeps its children). A set of more than @attr_tests
  # elements is not tested: the search walks, so that it does not cost much more than a walk.
  @attr_tests 32

  defp attr_candidates(set, _root, _sels) when map_size(set) > @attr_tests, do: :walk
  defp attr_candidates(set, root, sels), do: one_match(Map.keys(set), root, sels, [])

  defp one_match([], _root, _sels, acc), do: acc

  defp one_match([nid | rest], root, sels, acc) do
    cond do
      not (below?(nid, root) and matches?(nid, sels)) -> one_match(rest, root, sels, acc)
      acc == [] -> one_match(rest, root, sels, [nid])
      true -> :walk
    end
  end

  # what the last compound of a selector list with one selector gives an index to look in: its
  # id (`{:id, id}`), else its first `[name="v"]` (`{:attr, name, v}`), else nil
  defp selector_key([[{_comb, compound} | _]]) do
    Enum.find_value(compound, fn
      {:id, id} -> {:id, id}
      _ -> nil
    end) ||
      Enum.find_value(compound, fn
        {:attr, {name, "=", v}} -> {:attr, name, v}
        _ -> nil
      end)
  end

  defp selector_key(_sels), do: nil

  # The elements below a node that match, in document order (newest first). A walk does not
  # change the tree, so it reads the nodes from the table that it gets at the start. (A node
  # that is not in the table reads as a node with no children, as in `node/1`.)
  defp walk_matches([], _nodes, _sels, acc), do: acc

  defp walk_matches([k | rest], nodes, sels, acc) do
    case nodes do
      %{^k => n} ->
        acc = if node_matches?(n, sels), do: [k | acc], else: acc
        walk_matches(rest, nodes, sels, walk_matches(n.kids, nodes, sels, acc))

      _ ->
        walk_matches(rest, nodes, sels, acc)
    end
  end

  # the first element of `kids` and the nodes below them that matches, in the order of
  # `walk_matches/4`
  defp first_match([], _nodes, _sels), do: nil

  defp first_match([k | rest], nodes, sels) do
    case nodes do
      %{^k => n} ->
        if node_matches?(n, sels),
          do: k,
          else: first_match(n.kids, nodes, sels) || first_match(rest, nodes, sels)

      _ ->
        first_match(rest, nodes, sels)
    end
  end

  # the first element below a node that matches
  defp query_first(root, selector) do
    sels = parse_selectors(selector)

    unless tag_absent?(st(), sels) do
      case candidates(sels, root) do
        :walk -> first_match(node(root).kids, st().nodes, sels)
        nids -> Enum.find(nids, &(below?(&1, root) and matches?(&1, sels)))
      end
    end
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
    host = Str.downcase(host)

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
  defp frame_by_index(key) when is_binary(key) do
    with {i, ""} <- Integer.parse(key),
         d when d != nil <- Enum.at(child_frames(st().doc), i) do
      {:ok, aux_host(if(d == st().main, do: :window, else: {:window, d}), :window)}
    else
      _ -> :error
    end
  end

  defp frame_by_index(_), do: :error

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
  # over and over: the index of the ids says which elements might be the one.
  defp named_nid(_doc, ""), do: nil
  defp named_nid(doc, name), do: element_by_id(doc, name)

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

  # (scripts read `location` again and again, and `URI.parse/1` runs two regexes that load their
  # patterns again on each call: so the parts of each URL are kept)
  defp url_parts do
    url = st().url

    memo({:url_parts, url}, fn ->
      uri = URI.parse(url)
      path = if uri.path in [nil, ""], do: "/", else: uri.path
      %{uri: uri, path: path, query: uri.query, fragment: uri.fragment}
    end)
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
    scheme = v |> to_str() |> String.trim_trailing(":") |> Str.downcase()

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

  # `delete window.x`: a global variable of the window's realm goes, as on the global object
  # (`Browser.JS.Global.host_delete/2`); a `var` stays. On the window of a frame that went,
  # only an own property of the wrapper can go.
  def host_delete(data, key) when is_binary(key) and (data == :window or is_tuple(data)) do
    case data do
      {:window, _} ->
        in_window_realm(data, fn -> Browser.JS.Global.host_delete(:global, key) end, :default)

      :window ->
        in_window_realm(data, fn -> Browser.JS.Global.host_delete(:global, key) end, :default)

      _ ->
        :default
    end
  end

  def host_delete(_other, _key), do: :default

  @doc false
  # Runs `fun` in the realm of the window `data` (`:window` or `{:window, doc}`). The window
  # of a frame that went has no realm: then it gives `dead` and touches no global scope (the
  # running realm is not the window's).
  def in_window_realm(data, fun, dead) do
    {doc, :window} = split_realm(data)
    if realm_alive?(doc), do: in_realm(doc, fun), else: dead
  end

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
      for e <- elements_deep([nid]), node(e).kind == :element, ctor = registered(node(e).tag) do
        if MapSet.member?(st().ce_done, e) do
          call_callback(e, "connectedCallback", [])
        else
          upgrade(e, ctor)
        end
      end
    end

    :ok
  end

  # the nodes and the elements below them, and the ones in the shadow roots of those
  defp elements_deep(roots) do
    Enum.flat_map(roots, fn r ->
      all = [r | elements(r)]

      all ++
        Enum.flat_map(all, fn e ->
          case node(e).shadow do
            nil -> []
            sh -> elements_deep([sh])
          end
        end)
    end)
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
    if Process.get(:dom_has_iframe) && frame_in_doc?(st(), nid) && connected?(nid) do
      for e <- frames_in(nid), do: load_frame(e)
    end

    :ok
  end

  # the realms of the frames in a subtree that is leaving the document go with it
  defp frames_leaving(nid) do
    if Process.get(:dom_has_iframe) && st().frames != %{} && frame_in_doc?(st(), nid) do
      for e <- frames_in(nid) do
        cancel_frame_load(e)
        if d = Map.get(st().frames, e), do: destroy_realm(d)
      end
    end

    :ok
  end

  # The `<iframe>` elements in the subtree of `nid` (`nid` too), in tree order. A page has few
  # of them, so a walk up from each one costs less than a walk of a large subtree. Many nodes
  # move for each change of a large page that has a frame (a Speedometer suite runs in one).
  # A walk up costs the depth of the `<iframe>`, so a small subtree (at most
  # @frames_walk_down nodes for each `<iframe>`) gets the walk down: a text node that goes
  # into a page with deep frames does not walk up from each frame.
  @frames_walk_up 16
  @frames_walk_down 16

  defp frames_in(nid) do
    s = st()
    count = map_size(s.iframes)

    cond do
      count > @frames_walk_up ->
        for e <- [nid | descendants(nid)], iframe?(s.nodes, e), do: e

      (found = walk_frames(s.nodes, [[nid]], count * @frames_walk_down, [])) != :many ->
        :lists.reverse(found)

      true ->
        case for({e, _} <- s.iframes, e == nid or below?(e, nid), iframe?(s.nodes, e), do: e) do
          [_, _ | _] = found ->
            set = Map.new(found, &{&1, true})
            for e <- [nid | descendants(nid)], is_map_key(set, e), do: e

          found ->
            found
        end
    end
  end

  # True when an `<iframe>` has the document of `nid`. A node in the subtree of `nid` has the
  # document of `nid` (`adopt/2` moves a whole subtree, and `destroy_realm/1` also finds the
  # nodes of a document by this field), so with no such `<iframe>` the subtree has none and
  # `frames_in/1` has nothing to find. Most changes are in a document with no `<iframe>`, as
  # the app in the frame of a Speedometer suite: they then do no walk.
  defp frame_in_doc?(s, nid) do
    case s.nodes do
      %{^nid => %{doc: doc}} ->
        nodes = s.nodes
        Enum.any?(Map.keys(s.iframes), fn e -> match?(%{^e => %{doc: ^doc}}, nodes) end)

      _ ->
        true
    end
  end

  # The `<iframe>`s of the subtrees of the nodes in `lists`, in pre-order (newest first). The
  # walk stops with :many when it passes more than `budget` nodes.
  defp walk_frames(_nodes, _lists, budget, _acc) when budget < 0, do: :many
  defp walk_frames(_nodes, [], _budget, acc), do: acc
  defp walk_frames(nodes, [[] | lists], budget, acc), do: walk_frames(nodes, lists, budget, acc)

  defp walk_frames(nodes, [[k | rest] | lists], budget, acc) do
    case nodes do
      %{^k => %{kind: :element, tag: "iframe", kids: kids}} ->
        walk_frames(nodes, [kids, rest | lists], budget - 1, [k | acc])

      %{^k => %{kids: kids}} ->
        walk_frames(nodes, [kids, rest | lists], budget - 1, acc)

      _ ->
        walk_frames(nodes, [rest | lists], budget - 1, acc)
    end
  end

  defp iframe?(nodes, e), do: match?(%{^e => %{kind: :element, tag: "iframe"}}, nodes)

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
    name = Str.downcase(to_str(name))

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

  # the focused form control, if it is still in the document
  defp ctl_focused do
    case st().focus_ctl do
      nil -> nil
      nid -> if Map.has_key?(st().nodes, nid) and connected?(nid), do: nid
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

      # a form control: the window gives it focus
      control?(nid) ->
        put_st(%{st() | focus_ctl: nid})
        out({:focus_control, ensure_nid(nid)})
        :ok

      # other elements a script may focus: the window has nothing to show for them
      script_focusable?(nid) ->
        put_st(%{st() | focus_ctl: nid})
        :ok

      true ->
        :ok
    end
  end

  defp script_focusable?(nid) do
    n = node(nid)

    n.kind == :element and
      (n.tag == "dialog" or get_attr(n, "tabindex") != nil or
         (n.tag == "a" and get_attr(n, "href") != nil))
  end

  defp control?(nid) do
    n = node(nid)

    n.kind == :element and n.tag in ["input", "select", "textarea", "button"] and
      get_attr(n, "disabled") == nil and not (n.tag == "input" and type_of(n) == "hidden")
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
  A click on a link, which the layout reports as `href` over the element it numbers `nid`. When
  the link is in a frame, the frame follows it (`target="_top"` and `"_parent"` send the
  page, or the frame around, instead): `:frame`. A link of the page itself is for the session:
  `:page`. A link with a `download` attribute is not followed: the outbox gets a
  `{:download, ...}` (see `download/1`) and the answer is `:download`.
  """
  def follow_link(nid, href) do
    id = nid && nid_numbered(nid)
    if id != nil and download(id), do: :download, else: follow_link_in(id, href)
  end

  defp follow_link_in(id, href) do
    main = st().main

    with id when id != nil <- id,
         doc when doc != main <- node(id).doc,
         %{parent: parent} <- frame_of(doc) do
      target = link_target([id | ancestors(id)])

      case target do
        t when t in ["_top", "_parent"] ->
          # the frame's own address is the base of a link that leaves it
          url = in_realm(doc, fn -> resolve_url(href) end)

          if t == "_top" or parent == st().main do
            out({:navigate, url, :push})
          else
            in_realm(parent, fn -> navigate_to(url) end)
          end

        _ ->
          in_realm(doc, fn -> navigate_to(resolve_url(href)) end)
      end

      :frame
    else
      _ -> :page
    end
  end

  # A click on `nid`, or on an element in it, that is a link with a `download` attribute: the
  # session saves what it points to instead of going there. The outbox gets
  # `{:download, url, name, data}`, with `data` the content of a `blob:` URL of the link's
  # document (the session cannot read the blobs of the page), else nil. True when it did.
  defp download(nid) do
    case Enum.find([nid | ancestors(nid)], &download_link?/1) do
      nil ->
        false

      a ->
        n = node(a)

        {url, data} =
          in_realm(n.doc, fn ->
            url = resolve_url(get_attr(n, "href"))
            {url, blob_text(url)}
          end)

        out({:download, url, get_attr(n, "download"), data})
        true
    end
  end

  defp download_link?(id) do
    n = node(id)

    n.kind == :element and n.tag in ["a", "area"] and get_attr(n, "href") != nil and
      get_attr(n, "download") != nil
  end

  # (the web API prelude keeps the blobs of `URL.createObjectURL`, see `Browser.JS.WebAPI`)
  defp blob_text("blob:" <> _ = url) do
    with {:obj, _} = u <- deref_global("URL"),
         f = Interp.get(u, "__blobText"),
         true <- function?(f),
         text when text != :undefined <- call(f, :undefined, [url]) do
      to_str(text)
    else
      _ -> nil
    end
  end

  defp blob_text(_url), do: nil

  defp link_target(chain) do
    Enum.find_value(chain, fn id ->
      n = node(id)
      if n.kind == :element and n.tag == "a", do: get_attr(n, "target") || "", else: nil
    end)
  end

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
  # (the backdrop of a modal dialog, which has the dialog's number made negative, is the dialog)
  defp nid_numbered(n) when is_integer(n) and n < 0, do: nid_numbered(-n - 1)

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
      # (`action` is the editing prelude's, see `ed_call/2`. It is there at boot, so that a
      # frame that ran the prelude and went gives it back, see `Browser.JS.Intrinsics`: the
      # function of the frame holds the frame's whole page)
      {"action", :undefined},
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

  # ── event interfaces ───────────────────────────────────────

  @modifier_members [
    {"ctrlKey", false},
    {"shiftKey", false},
    {"altKey", false},
    {"metaKey", false}
  ]

  # The event interfaces: the name, the parent and the members of the init dictionary, with
  # their default values. An event has the members of its interface and of each parent.
  @event_classes [
    {"Event", nil, []},
    {"CustomEvent", "Event", [{"detail", :null}]},
    {"SubmitEvent", "Event", [{"submitter", :null}]},
    {"UIEvent", "Event", [{"view", :null}, {"detail", 0.0}]},
    {"FocusEvent", "UIEvent", [{"relatedTarget", :null}]},
    {"MouseEvent", "UIEvent",
     [
       {"screenX", 0.0},
       {"screenY", 0.0},
       {"clientX", 0.0},
       {"clientY", 0.0},
       {"button", 0.0},
       {"buttons", 0.0},
       {"relatedTarget", :null},
       {"movementX", 0.0},
       {"movementY", 0.0}
     ] ++ @modifier_members},
    {"PointerEvent", "MouseEvent",
     [
       {"pointerId", 0.0},
       {"width", 1.0},
       {"height", 1.0},
       {"pressure", 0.0},
       {"tangentialPressure", 0.0},
       {"tiltX", 0.0},
       {"tiltY", 0.0},
       {"twist", 0.0},
       {"pointerType", ""},
       {"isPrimary", false}
     ]},
    {"WheelEvent", "MouseEvent",
     [{"deltaX", 0.0}, {"deltaY", 0.0}, {"deltaZ", 0.0}, {"deltaMode", 0.0}]},
    {"DragEvent", "MouseEvent", [{"dataTransfer", :null}]},
    {"KeyboardEvent", "UIEvent",
     [
       {"key", ""},
       {"code", ""},
       {"location", 0.0},
       {"repeat", false},
       {"isComposing", false},
       {"charCode", 0.0},
       {"keyCode", 0.0}
     ] ++ @modifier_members},
    {"InputEvent", "UIEvent",
     [{"data", :null}, {"isComposing", false}, {"inputType", ""}, {"dataTransfer", :null}]},
    {"CompositionEvent", "UIEvent", [{"data", ""}]}
  ]

  # each interface with all its members (the parents' first) and its chain of names
  @event_members (for {name, _, _} <- @event_classes, into: %{} do
                    chain =
                      Stream.unfold(name, fn
                        nil -> nil
                        n -> {n, elem(List.keyfind(@event_classes, n, 0), 1)}
                      end)
                      |> Enum.reverse()

                    members =
                      Enum.flat_map(chain, &elem(List.keyfind(@event_classes, &1, 0), 2))
                      |> Enum.uniq_by(&elem(&1, 0))

                    {name, %{chain: chain, members: members}}
                  end)

  # the interface of an event that the browser fires, by its type
  @pointer_types ~w(click auxclick contextmenu pointerdown pointerup pointermove pointerover
                    pointerout pointerenter pointerleave pointercancel gotpointercapture
                    lostpointercapture)
  @mouse_types ~w(mousedown mouseup mousemove mouseover mouseout mouseenter mouseleave dblclick)
  @drag_types ~w(drag dragstart dragend dragenter dragleave dragover drop)

  defp event_class(type) when type in @pointer_types, do: "PointerEvent"
  defp event_class(type) when type in @mouse_types, do: "MouseEvent"
  defp event_class(type) when type in @drag_types, do: "DragEvent"
  defp event_class(type) when type in ~w(keydown keyup keypress), do: "KeyboardEvent"
  defp event_class(type) when type in ~w(focus blur focusin focusout), do: "FocusEvent"
  defp event_class(type) when type in ~w(input beforeinput), do: "InputEvent"

  defp event_class(type) when type in ~w(compositionstart compositionupdate compositionend),
    do: "CompositionEvent"

  defp event_class("wheel"), do: "WheelEvent"
  defp event_class("submit"), do: "SubmitEvent"
  defp event_class(_type), do: "Event"

  defp event_proto(class), do: proto({:dom, :event, class})

  # the members of `class` that `given` (a member name -> value or :undefined) does not set
  # get their defaults; a given value becomes the type of its default
  defp event_members(class, given) do
    for {k, default} <- @event_members[class].members do
      v = given.(k)

      cond do
        v == :undefined -> {k, default}
        is_float(default) -> {k, float(to_num(v))}
        is_boolean(default) -> {k, truthy(v)}
        is_binary(default) -> {k, to_str(v)}
        true -> {k, v}
      end
    end
  end

  # a mouse event also has `x`, `y`, `pageX`, ... which come from `clientX` and `clientY`
  defp mouse_aliases(class, members) do
    if "MouseEvent" in @event_members[class].chain do
      {_, cx} = List.keyfind(members, "clientX", 0)
      {_, cy} = List.keyfind(members, "clientY", 0)

      [
        {"x", cx},
        {"y", cy},
        {"pageX", cx},
        {"pageY", cy},
        {"offsetX", 0.0},
        {"offsetY", 0.0},
        {"which", float(to_num(elem(List.keyfind(members, "button", 0), 1))) + 1.0}
      ]
    else
      []
    end
  end

  # true when `ev` has the prototype of `class` in its chain
  defp event_of_class?({:obj, _} = ev, class) do
    target = event_proto(class)

    walk = fn walk, o ->
      case Browser.JS.Props.get_prototype_of(o) do
        {:obj, _} = p -> p == target or walk.(walk, p)
        _ -> false
      end
    end

    target != nil and walk.(walk, ev)
  end

  defp event_of_class?(_ev, _class), do: false

  # the event constructors, each with its own prototype (`Event` <- `UIEvent` <- `MouseEvent`
  # <- `PointerEvent`, ...)
  defp install_event_classes(scope, event) do
    for {name, parent, _} <- @event_classes do
      p =
        if name == "Event" do
          event
        else
          p = new_object([], event_proto(parent))
          Interp.put_tag(p, name)
          p
        end

      put_proto({:dom, :event, name}, p)
      ctor(scope, name, p, &construct_event(name, &1, &2))
      install_event_methods(name, p)
    end
  end

  defp install_event_methods(name, p) when name in ["MouseEvent", "KeyboardEvent"] do
    def_fn(p, "getModifierState", fn this, args ->
      case to_str(arg(args, 0)) do
        "Control" -> truthy(Interp.get(this, "ctrlKey"))
        "Shift" -> truthy(Interp.get(this, "shiftKey"))
        "Alt" -> truthy(Interp.get(this, "altKey"))
        "Meta" -> truthy(Interp.get(this, "metaKey"))
        _ -> false
      end
    end)
  end

  defp install_event_methods(_name, _p), do: :ok

  # `new MouseEvent(type, init)` and the others
  defp construct_event(class, _this, args) do
    init = arg(args, 1)
    obj? = match?({:obj, _}, init)
    given = fn k -> if obj?, do: Interp.get(init, k), else: :undefined end
    members = event_members(class, given)
    own = Enum.map(members, &elem(&1, 0))

    ev =
      new_object(
        [
          {"type", to_str(arg(args, 0))},
          {"target", :null},
          {"currentTarget", :null},
          {"defaultPrevented", false},
          {"bubbles", truthy(given.("bubbles"))},
          {"cancelable", truthy(given.("cancelable"))},
          {"composed", truthy(given.("composed"))},
          {"eventPhase", 0.0},
          {"isTrusted", false},
          {"timeStamp", Browser.JS.Builtins.perf_now()}
        ] ++ members ++ mouse_aliases(class, members),
        event_proto(class)
      )

    if given.("clientX") != :undefined or given.("clientY") != :undefined,
      do: put_hidden(ev, "__pos", true)

    # (other keys of `init` are kept too, as before: some pages read them from the event)
    if obj? do
      for k <- own_keys(init),
          k not in ["bubbles", "cancelable", "composed"] and k not in own,
          do: put(ev, k, Interp.get(init, k))
    end

    ev
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

    Interp.declare(
      scope,
      "__set_shadow",
      native("__set_shadow", fn _, [host, root | _] ->
        h = nid_of(host)
        r = nid_of(root)
        update_node_quiet(h, &%{&1 | shadow: r})
        update_node_quiet(r, &%{&1 | shost: h})
        # (a host that is in the document: what is in its shadow root is too)
        if connected?(h), do: connect(r)
        :undefined
      end)
    )

    # the style sheets a shadow root adopts, as text (they apply inside the shadow tree)
    Interp.declare(
      scope,
      "__set_adopted",
      native("__set_adopted", fn _, [root, list | _] ->
        r = nid_of(root)
        texts = if array?(list), do: Enum.map(array_list(list), &to_str/1), else: []

        update_node(r, fn n ->
          %{n | internal: List.keystore(n.internal, "@adopted", 0, {"@adopted", texts})}
        end)

        :undefined
      end)
    )

    Interp.declare(scope, "__cur_doc", native("__cur_doc", fn _, _ -> wrap(st().doc) end))
    Interp.declare(scope, "__cur_loc", native("__cur_loc", fn _, _ -> loc_host() end))
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

  # `canvas.getContext("2d")`: one context per canvas. What a script draws is kept as a display
  # list in `Browser.Canvas` (the page paints it; the pixels are only made for `toDataURL`).
  # The style properties live on the context object, as plain properties.
  @canvas_props ~w(fillStyle strokeStyle lineWidth lineCap lineJoin miterLimit globalAlpha font
                   textAlign textBaseline lineDashOffset direction globalCompositeOperation
                   imageSmoothingEnabled imageSmoothingQuality shadowBlur shadowColor shadowOffsetX
                   shadowOffsetY filter letterSpacing __dash)

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
                {"lineCap", "butt"},
                {"lineJoin", "miter"},
                {"miterLimit", 10.0},
                {"globalAlpha", 1.0},
                {"font", "10px sans-serif"},
                {"textAlign", "start"},
                {"textBaseline", "alphabetic"},
                {"lineDashOffset", 0.0},
                {"direction", "ltr"},
                {"globalCompositeOperation", "source-over"},
                {"imageSmoothingEnabled", true},
                {"imageSmoothingQuality", "low"},
                {"shadowBlur", 0.0},
                {"shadowColor", "rgba(0, 0, 0, 0)"},
                {"shadowOffsetX", 0.0},
                {"shadowOffsetY", 0.0},
                {"filter", "none"},
                {"letterSpacing", "0px"},
                {"canvas", this}
              ],
              Process.get(:canvas_ctx_proto)
            )

          put_hidden(ctx, "__dash", new_array([]))
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
  # canvas's size (which also clears it). The size is the one that `canvas.width` and
  # `canvas.height` give (`canvas_size/2`), read from the node: each call of the context
  # comes here, and two reads through the properties of the element cost more than most
  # drawing calls.
  defp canvas_surface(this) do
    nid = this_nid(this)
    n = node(nid)

    if n.tag == "canvas" do
      w = trunc(canvas_size(n, "width"))
      h = trunc(canvas_size(n, "height"))

      case Process.get({:canvas, nid}) do
        %Browser.Canvas{w: ^w, h: ^h} = surface -> surface
        _ -> Browser.Canvas.new(w, h)
      end
    end
  end

  # `canvas.width` and `.height`: the attribute as a number, else 300 by 150
  defp canvas_size(n, name) do
    default = if name == "width", do: 300, else: 150

    case get_attr(n, name) do
      v when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {i, _} when i >= 0 -> i * 1.0
          _ -> default * 1.0
        end

      _ ->
        default * 1.0
    end
  end

  # `n` finite numbers from the arguments as floats, or nil: a call with a NaN or an infinite
  # argument does nothing, as the standard says
  defp canvas_nums(args, n) do
    vals = for i <- 0..(n - 1)//1, do: to_num(arg(args, i))
    if Enum.all?(vals, &is_number/1), do: Enum.map(vals, &(&1 * 1.0))
  end

  # changes the state of the canvas of `ctx` without drawing (the path, the transform)
  defp canvas_state(ctx, fun) do
    this = Interp.get(ctx, "canvas")

    with surface when surface != nil <- canvas_surface(this) do
      Process.put({:canvas, this_nid(this)}, fun.(surface))
    end

    :undefined
  end

  # draws on the canvas of `ctx`; the page has to be laid out again to show it
  defp canvas_draw(ctx, fun) do
    this = Interp.get(ctx, "canvas")

    with surface when surface != nil <- canvas_surface(this) do
      nid = this_nid(this)
      Process.put({:canvas, nid}, fun.(surface))
      update_node(nid, & &1)
    end

    :undefined
  end

  defp canvas_alpha(ctx),
    do: ctx |> Interp.get("globalAlpha") |> to_num_or_zero() |> min(1) |> max(0) |> Kernel.*(1.0)

  # the paint of `fillStyle` or `strokeStyle`: a colour, or a gradient, with the points the
  # script gave. (Patterns paint nothing.)
  defp canvas_paint(ctx, prop) do
    case Interp.get(ctx, prop) do
      {:obj, id} ->
        case Process.get({:canvas_grad, id}) do
          nil -> {:color, {0, 0, 0, 0}}
          grad -> gradient_paint(grad)
        end

      v ->
        case Browser.Color.parse_alpha(to_str(v)) do
          {r, g, b, a} -> {:color, {r, g, b, a}}
          _ -> {:color, {0, 0, 0, 255}}
        end
    end
  end

  defp gradient_paint(%{stops: []}), do: {:color, {0, 0, 0, 0}}
  defp gradient_paint(%{stops: [{_, color}]}), do: {:color, color}

  defp gradient_paint(%{kind: :linear, geom: geom, stops: stops}), do: {:linear, geom, stops}

  defp gradient_paint(%{kind: :radial, geom: {x0, y0, r0, x1, y1, r1}, stops: stops}) do
    if r1 <= 0 do
      {:color, stops |> List.last() |> elem(1)}
    else
      f = min(r0 / r1, 0.99)
      stops = if f > 0, do: Enum.map(stops, fn {o, c} -> {f + o * (1 - f), c} end), else: stops
      {:radial, {x1, y1, r1, x0, y0}, stops}
    end
  end

  defp canvas_line_style(ctx) do
    dash =
      case Interp.get(ctx, "__dash") do
        {:obj, _} = list ->
          nums = list |> array_list() |> Enum.map(&to_num_or_zero/1)
          if nums != [] and Enum.sum(nums) > 0, do: nums

        _ ->
          nil
      end

    %{
      width: ctx |> Interp.get("lineWidth") |> to_num_or_zero() |> Kernel.*(1.0),
      cap:
        case Interp.get(ctx, "lineCap") do
          "round" -> :round
          "square" -> :square
          _ -> :butt
        end,
      join:
        case Interp.get(ctx, "lineJoin") do
          "round" -> :round
          "bevel" -> :bevel
          _ -> :miter
        end,
      miter: ctx |> Interp.get("miterLimit") |> to_num_or_zero() |> Kernel.*(1.0),
      dash: dash
    }
  end

  defp canvas_text_style(ctx, prop) do
    %{
      paint: canvas_paint(ctx, prop),
      alpha: canvas_alpha(ctx),
      font: to_str(Interp.get(ctx, "font")),
      align:
        case Interp.get(ctx, "textAlign") do
          a when a in ["center"] -> :middle
          a when a in ["right", "end"] -> :end
          _ -> :start
        end,
      baseline:
        case Interp.get(ctx, "textBaseline") do
          "top" -> :top
          "hanging" -> :hanging
          "middle" -> :middle
          "bottom" -> :bottom
          "ideographic" -> :ideographic
          _ -> :alphabetic
        end
    }
  end

  # a path function shared by the context and `Path2D`: `c` is a `Browser.Canvas`
  @path_methods ~w(moveTo lineTo bezierCurveTo quadraticCurveTo arc arcTo ellipse rect roundRect
                   closePath)
  defp path_call(c, "closePath", _args), do: Browser.Canvas.close_path(c)

  defp path_call(c, name, args) do
    case path_args(name, args) do
      nil -> c
      {:error, kind, msg} -> throw_error(kind, msg)
      call -> apply_path_call(c, call)
    end
  end

  defp path_args(name, args) do
    n =
      case name do
        "moveTo" -> 2
        "lineTo" -> 2
        "bezierCurveTo" -> 6
        "quadraticCurveTo" -> 4
        "arc" -> 5
        "arcTo" -> 5
        "ellipse" -> 7
        "rect" -> 4
        "roundRect" -> 4
      end

    with nums when nums != nil <- canvas_nums(args, n) do
      case {name, nums} do
        {"arc", [_, _, r | _]} when r < 0 ->
          {:error, "IndexSizeError", "The radius provided (#{trunc(r)}) is negative."}

        {"arcTo", [_, _, _, _, r]} when r < 0 ->
          {:error, "IndexSizeError", "The radius provided (#{trunc(r)}) is negative."}

        {"ellipse", [_, _, rx, ry | _]} when rx < 0 or ry < 0 ->
          {:error, "IndexSizeError", "The radius provided is negative."}

        {"arc", nums} ->
          {:arc, nums, truthy(arg(args, 5))}

        {"ellipse", nums} ->
          {:ellipse, nums, truthy(arg(args, 7))}

        {"roundRect", nums} ->
          {:round_rect, nums, round_rect_radii(arg(args, 4))}

        {name, nums} ->
          {String.to_atom(Macro.underscore(name)), nums}
      end
    end
  end

  defp apply_path_call(c, {:move_to, [x, y]}), do: Browser.Canvas.move_to(c, x, y)
  defp apply_path_call(c, {:line_to, [x, y]}), do: Browser.Canvas.line_to(c, x, y)

  defp apply_path_call(c, {:bezier_curve_to, [a, b, d, e, f, g]}),
    do: Browser.Canvas.bezier_to(c, a, b, d, e, f, g)

  defp apply_path_call(c, {:quadratic_curve_to, [a, b, d, e]}),
    do: Browser.Canvas.quad_to(c, a, b, d, e)

  defp apply_path_call(c, {:arc_to, [a, b, d, e, r]}), do: Browser.Canvas.arc_to(c, a, b, d, e, r)
  defp apply_path_call(c, {:rect, [x, y, w, h]}), do: Browser.Canvas.rect(c, x, y, w, h)

  defp apply_path_call(c, {:arc, [x, y, r, a0, a1], ccw}),
    do: Browser.Canvas.arc(c, x, y, r, a0, a1, ccw)

  defp apply_path_call(c, {:ellipse, [x, y, rx, ry, rot, a0, a1], ccw}),
    do: Browser.Canvas.ellipse(c, x, y, rx, ry, rot, a0, a1, ccw)

  defp apply_path_call(c, {:round_rect, [x, y, w, h], radii}),
    do: Browser.Canvas.round_rect(c, x, y, w, h, radii)

  # `roundRect` radii: a number, or a list of one to four numbers (or `{x, y}` points)
  defp round_rect_radii(v) do
    radius = fn
      {:obj, _} = o -> o |> Interp.get("x") |> to_num_or_zero()
      n -> to_num_or_zero(n)
    end

    list =
      case v do
        :undefined ->
          [0]

        {:obj, _} = o ->
          if Interp.array?(o), do: Enum.map(array_list(o), radius), else: [radius.(o)]

        n ->
          [radius.(n)]
      end

    case list do
      [] -> [0.0, 0.0, 0.0, 0.0]
      [a] -> [a, a, a, a]
      [a, b] -> [a, b, a, b]
      [a, b, c] -> [a, b, c, b]
      [a, b, c, d | _] -> [a, b, c, d]
    end
    |> Enum.map(&(&1 * 1.0))
  end

  defp matrix_args(args) do
    case arg(args, 0) do
      {:obj, _} = m ->
        vals = for k <- ~w(a b c d e f), do: to_num(Interp.get(m, k))
        if Enum.all?(vals, &is_number/1), do: List.to_tuple(Enum.map(vals, &(&1 * 1.0)))

      _ ->
        with nums when nums != nil <- canvas_nums(args, 6), do: List.to_tuple(nums)
    end
  end

  defp canvas_fill_args(args) do
    case arg(args, 0) do
      {:obj, id} ->
        case Process.get({:path2d, id}) do
          nil -> {nil, fill_rule(arg(args, 0))}
          path -> {path, fill_rule(arg(args, 1))}
        end

      rule ->
        {nil, fill_rule(rule)}
    end
  end

  defp fill_rule("evenodd"), do: :evenodd
  defp fill_rule(_), do: :nonzero

  defp install_canvas_context(p) do
    for name <- @path_methods do
      def_fn(p, name, fn this, args ->
        canvas_state(this, &path_call(&1, name, args))
      end)
    end

    def_fn(p, "beginPath", fn this, _ -> canvas_state(this, &Browser.Canvas.begin_path/1) end)

    def_fn(p, "fill", fn this, args ->
      {path, rule} = canvas_fill_args(args)
      paint = canvas_paint(this, "fillStyle")
      alpha = canvas_alpha(this)
      draw = &Browser.Canvas.fill(&1, paint, rule, alpha)

      canvas_draw(this, fn c ->
        if path, do: Browser.Canvas.with_path(c, path, draw), else: draw.(c)
      end)
    end)

    def_fn(p, "stroke", fn this, args ->
      path =
        with {:obj, id} <- arg(args, 0), do: Process.get({:path2d, id}), else: (_ -> nil)

      paint = canvas_paint(this, "strokeStyle")
      alpha = canvas_alpha(this)
      style = canvas_line_style(this)
      draw = &Browser.Canvas.stroke(&1, paint, style, alpha)

      canvas_draw(this, fn c ->
        if path, do: Browser.Canvas.with_path(c, path, draw), else: draw.(c)
      end)
    end)

    def_fn(p, "clip", fn this, args ->
      {path, _rule} = canvas_fill_args(args)

      canvas_state(this, fn c ->
        if path,
          do: Browser.Canvas.with_path(c, path, &Browser.Canvas.clip/1),
          else: Browser.Canvas.clip(c)
      end)
    end)

    def_fn(p, "isPointInPath", fn _, _ -> false end)
    def_fn(p, "isPointInStroke", fn _, _ -> false end)

    def_fn(p, "fillRect", fn this, args ->
      with [x, y, w, h] <- canvas_nums(args, 4) do
        paint = canvas_paint(this, "fillStyle")
        alpha = canvas_alpha(this)
        canvas_draw(this, &Browser.Canvas.fill_rect(&1, x, y, w, h, paint, alpha))
      else
        _ -> :undefined
      end
    end)

    def_fn(p, "strokeRect", fn this, args ->
      with [x, y, w, h] <- canvas_nums(args, 4) do
        paint = canvas_paint(this, "strokeStyle")
        alpha = canvas_alpha(this)
        style = canvas_line_style(this)
        canvas_draw(this, &Browser.Canvas.stroke_rect(&1, x, y, w, h, paint, style, alpha))
      else
        _ -> :undefined
      end
    end)

    def_fn(p, "clearRect", fn this, args ->
      with [x, y, w, h] <- canvas_nums(args, 4) do
        canvas_draw(this, &Browser.Canvas.clear_rect(&1, x, y, w, h))
      else
        _ -> :undefined
      end
    end)

    for {name, prop} <- [{"fillText", "fillStyle"}, {"strokeText", "strokeStyle"}] do
      def_fn(p, name, fn this, args ->
        with [x, y] <- canvas_nums(Enum.drop(args, 1), 2) do
          style = canvas_text_style(this, prop)
          canvas_draw(this, &Browser.Canvas.text(&1, to_str(arg(args, 0)), x, y, style))
        else
          _ -> :undefined
        end
      end)
    end

    def_fn(p, "measureText", fn this, args ->
      text = to_str(arg(args, 0))
      font = Browser.Canvas.parse_font(to_str(Interp.get(this, "font")))
      w = Browser.Canvas.text_width(text, font)
      s = font.size

      new_object([
        {"width", w},
        {"actualBoundingBoxLeft", 0.0},
        {"actualBoundingBoxRight", w},
        {"actualBoundingBoxAscent", 0.72 * s},
        {"actualBoundingBoxDescent", 0.2 * s},
        {"fontBoundingBoxAscent", 0.8 * s},
        {"fontBoundingBoxDescent", 0.2 * s},
        {"emHeightAscent", 0.8 * s},
        {"emHeightDescent", 0.2 * s},
        {"alphabeticBaseline", 0.0}
      ])
    end)

    def_fn(p, "save", fn this, _ ->
      props = for name <- @canvas_props, do: {name, Interp.get(this, name)}
      canvas_state(this, &Browser.Canvas.save(&1, props))
    end)

    def_fn(p, "restore", fn this, _ ->
      canvas_state(this, fn c ->
        {c, props} = Browser.Canvas.restore(c)
        for {name, v} <- props || [], do: Interp.put(this, name, v)
        c
      end)
    end)

    def_fn(p, "scale", fn this, args ->
      with [x, y] <- canvas_nums(args, 2),
           do: canvas_state(this, &Browser.Canvas.scale(&1, x, y)),
           else: (_ -> :undefined)
    end)

    def_fn(p, "translate", fn this, args ->
      with [x, y] <- canvas_nums(args, 2),
           do: canvas_state(this, &Browser.Canvas.translate(&1, x, y)),
           else: (_ -> :undefined)
    end)

    def_fn(p, "rotate", fn this, args ->
      with [a] <- canvas_nums(args, 1),
           do: canvas_state(this, &Browser.Canvas.rotate(&1, a)),
           else: (_ -> :undefined)
    end)

    def_fn(p, "transform", fn this, args ->
      with m when m != nil <- matrix_args(args),
           do: canvas_state(this, &Browser.Canvas.transform(&1, m)),
           else: (_ -> :undefined)
    end)

    def_fn(p, "setTransform", fn this, args ->
      with m when m != nil <-
             if(args == [], do: {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}, else: matrix_args(args)),
           do: canvas_state(this, &Browser.Canvas.set_transform(&1, m)),
           else: (_ -> :undefined)
    end)

    def_fn(p, "resetTransform", fn this, _ ->
      canvas_state(this, &Browser.Canvas.reset_transform/1)
    end)

    def_fn(p, "getTransform", fn this, _ ->
      {a, b, c, d, e, f} =
        case canvas_surface(Interp.get(this, "canvas")) do
          nil -> {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}
          surface -> Browser.Canvas.matrix(surface)
        end

      new_object([
        {"a", a},
        {"b", b},
        {"c", c},
        {"d", d},
        {"e", e},
        {"f", f},
        {"m11", a},
        {"m12", b},
        {"m21", c},
        {"m22", d},
        {"m41", e},
        {"m42", f},
        {"is2D", true},
        {"isIdentity", {a, b, c, d, e, f} == {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}}
      ])
    end)

    def_fn(p, "setLineDash", fn this, args ->
      segments =
        case arg(args, 0) do
          {:obj, _} = list -> Enum.map(array_list(list), &to_num/1)
          _ -> []
        end

      # an odd count is repeated; a negative or non-finite length makes the call a no-op
      if Enum.all?(segments, &(is_number(&1) and &1 >= 0)) do
        segments = if rem(length(segments), 2) == 1, do: segments ++ segments, else: segments
        put_hidden(this, "__dash", new_array(Enum.map(segments, &(&1 * 1.0))))
      end

      :undefined
    end)

    def_fn(p, "getLineDash", fn this, _ ->
      case Interp.get(this, "__dash") do
        {:obj, _} = list -> new_array(array_list(list))
        _ -> new_array([])
      end
    end)

    def_fn(p, "createLinearGradient", fn _this, args ->
      case canvas_nums(args, 4) do
        [x0, y0, x1, y1] -> new_gradient(%{kind: :linear, geom: {x0, y0, x1, y1}, stops: []})
        nil -> throw_error("TypeError", "createLinearGradient: arguments must be finite numbers")
      end
    end)

    def_fn(p, "createRadialGradient", fn _this, args ->
      case canvas_nums(args, 6) do
        [x0, y0, r0, x1, y1, r1] when r0 >= 0 and r1 >= 0 ->
          new_gradient(%{kind: :radial, geom: {x0, y0, r0, x1, y1, r1}, stops: []})

        nil ->
          throw_error("TypeError", "createRadialGradient: arguments must be finite numbers")

        _ ->
          throw_error("IndexSizeError", "The radius provided is negative.")
      end
    end)

    # a conic gradient is drawn as a colour: its first stop
    def_fn(p, "createConicGradient", fn _this, _ ->
      new_gradient(%{kind: :linear, geom: {0.0, 0.0, 1.0, 0.0}, stops: []})
    end)

    def_fn(p, "drawImage", fn this, args ->
      source = arg(args, 0)

      with {:obj, _} <- source,
           %Browser.Canvas{} = src <- canvas_source(source),
           [a, b | rest] <- canvas_nums(Enum.drop(args, 1), min(length(args) - 1, 8)) do
        {sx, sy, sw, sh, dx, dy, dw, dh} =
          case rest do
            [] -> {0.0, 0.0, src.w * 1.0, src.h * 1.0, a, b, src.w * 1.0, src.h * 1.0}
            [dw, dh] -> {0.0, 0.0, src.w * 1.0, src.h * 1.0, a, b, dw, dh}
            [sw, sh, dx, dy, dw, dh] -> {a, b, sw, sh, dx, dy, dw, dh}
            _ -> {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0}
          end

        alpha = canvas_alpha(this)

        canvas_draw(
          this,
          &Browser.Canvas.draw_canvas(&1, src, sx, sy, sw, sh, dx, dy, dw, dh, alpha)
        )
      else
        _ -> :undefined
      end
    end)
  end

  # the pixels of an element used as an image source, if it is a canvas with a surface
  defp canvas_source({:obj, id}) do
    case deref(id) do
      %{class: :host, host: {__MODULE__, nid}} when is_integer(nid) ->
        if node(nid).tag == "canvas", do: Process.get({:canvas, nid})

      _ ->
        nil
    end
  end

  defp new_gradient(data) do
    grad = new_object([], Process.get(:canvas_grad_proto))
    {:obj, id} = grad
    Process.put({:canvas_grad, id}, data)
    grad
  end

  defp install_canvas_gradient(p) do
    def_fn(p, "addColorStop", fn this, args ->
      {:obj, id} = this
      offset = to_num(arg(args, 0))

      unless is_number(offset) and offset >= 0 and offset <= 1,
        do: throw_error("IndexSizeError", "The provided value is outside the range (0.0, 1.0).")

      case Browser.Color.parse_alpha(to_str(arg(args, 1))) do
        {r, g, b, a} ->
          grad = Process.get({:canvas_grad, id})
          # stops of the same offset keep the order they came in
          stops = Enum.sort_by(grad.stops ++ [{offset * 1.0, {r, g, b, a}}], &elem(&1, 0))
          Process.put({:canvas_grad, id}, %{grad | stops: stops})

        _ ->
          throw_error(
            "SyntaxError",
            "The value provided ('#{to_str(arg(args, 1))}') could not be parsed as a color."
          )
      end

      :undefined
    end)
  end

  # `new Path2D()`, `new Path2D(path)` or `new Path2D("M0 0 L10 10")`: a path kept apart from
  # any canvas, to be passed to `fill`, `stroke` and `clip`
  defp install_path2d(scope) do
    proto = new_object([])

    for name <- @path_methods do
      def_fn(proto, name, fn this, args -> path2d_update(this, &path_call(&1, name, args)) end)
    end

    def_fn(proto, "addPath", fn this, args ->
      other =
        with {:obj, oid} <- arg(args, 0), do: Process.get({:path2d, oid}), else: (_ -> nil)

      m =
        case matrix_args([arg(args, 1)]) do
          nil -> {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}
          m -> m
        end

      if other, do: path2d_update(this, &Browser.Canvas.add_path(&1, other, m))
      :undefined
    end)

    Process.put(:path2d_proto, proto)

    ctor(scope, "Path2D", proto, fn _this, args ->
      obj = new_object([], proto)
      {:obj, id} = obj

      path =
        case arg(args, 0) do
          :undefined ->
            Browser.Canvas.new(1, 1)

          {:obj, oid} = _other ->
            Process.get({:path2d, oid}) || Browser.Canvas.new(1, 1)

          d ->
            Browser.Canvas.from_segments(Browser.Svg.PathData.parse(to_str(d)))
        end

      Process.put({:path2d, id}, path)
      obj
    end)
  end

  defp path2d_update({:obj, id}, fun) do
    Process.put({:path2d, id}, fun.(Process.get({:path2d, id})))
    :undefined
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

    # The script's event itself goes to the listeners. A click that is a `MouseEvent` runs the
    # activation behavior too, as a click of `click()` does.
    def_fn(p, "dispatchEvent", fn this, args ->
      ev = arg(args, 0)

      unless match?({:obj, _}, ev),
        do: throw_error("TypeError", "parameter 1 is not of type 'Event'.")

      type = to_str(Interp.get(ev, "type"))

      init = %{
        event: ev,
        bubbles: truthy(Interp.get(ev, "bubbles")),
        cancelable: truthy(Interp.get(ev, "cancelable")),
        composed: truthy(Interp.get(ev, "composed")),
        activate: type == "click" and event_of_class?(ev, "MouseEvent")
      }

      dispatch(listener_target(this), type, init) == :ok
    end)
  end

  defp listener_target({:obj, id} = this) do
    case deref(id) do
      %{class: :host, host: {__MODULE__, :window}} -> :window
      %{class: :host, host: {__MODULE__, {:window, _} = key}} -> key
      %{class: :host, host: {__MODULE__, nid}} when is_integer(nid) -> nid
      # (`new EventTarget()` and the classes that extend it: the object is its own target)
      %{class: _} -> {:objt, id}
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
    def_fn(p, "getRootNode", fn this, _ -> wrap(top_of(this_nid(this))) end)

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
      wrap_or_null(query_first(this_nid(this), to_str(arg(args, 0))))
    end)

    def_fn(p, "querySelectorAll", fn this, args ->
      nodes_array(query_all(this_nid(this), to_str(arg(args, 0))))
    end)

    # (a fragment and a shadow root search their own tree; the document has its own method)
    def_fn(p, "getElementById", fn this, args ->
      wrap_or_null(element_by_id(this_nid(this), to_str(arg(args, 0))))
    end)

    def_fn(p, "getElementsByTagName", fn this, args ->
      tag = Str.downcase(to_str(arg(args, 0)))

      nodes_array(elements_tagged(this_nid(this), if(tag == "*", do: nil, else: tag)))
    end)

    def_fn(p, "getElementsByClassName", fn this, args ->
      wanted = split_words(to_str(arg(args, 0)))

      # (a string with no class name gives no element)
      els = if wanted == [], do: [], else: elements(this_nid(this))
      nodes_array(Enum.filter(els, fn e -> Enum.all?(wanted, &(&1 in classes(e))) end))
    end)
  end

  # a string is a text node
  defp to_node(v) when is_binary(v), do: new_node(%{kind: :text, text: v})
  defp to_node(v) when is_number(v), do: new_node(%{kind: :text, text: to_str(v)})
  defp to_node(v), do: nid_of(v)

  defp install_element(p) do
    def_fn(p, "getAttribute", fn this, args ->
      case get_attr(node(this_nid(this)), Str.downcase(to_str(arg(args, 0)))) do
        nil -> :null
        v -> v
      end
    end)

    def_fn(p, "setAttribute", fn this, args ->
      set_attr(this_nid(this), to_str(arg(args, 0)), to_str(arg(args, 1)))
      :undefined
    end)

    def_fn(p, "hasAttribute", fn this, args ->
      get_attr(node(this_nid(this)), Str.downcase(to_str(arg(args, 0)))) != nil
    end)

    def_fn(p, "removeAttribute", fn this, args ->
      remove_attr(this_nid(this), to_str(arg(args, 0)))
      :undefined
    end)

    def_fn(p, "toggleAttribute", fn this, args ->
      name = Str.downcase(to_str(arg(args, 0)))
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
      name = Str.downcase(to_str(arg(args, 0)))

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
      nid = this_nid(this)

      if st().focus_ctl == nid do
        put_st(%{st() | focus_ctl: nil})
        out({:modal, :blur})
      end

      if st().focus_ed == nid, do: ed_blur()
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

    # the dialog is (or is no longer) shown modally; see `Browser.Modal`
    def_fn(p, "__setModal", fn this, args ->
      nid = this_nid(this)
      on? = truthy(arg(args, 0))
      was? = List.keymember?(node(nid).internal, "@modal", 0)

      update_node(nid, fn n ->
        internal = List.keydelete(n.internal, "@modal", 0)
        %{n | internal: if(on?, do: internal ++ [{"@modal", 1}], else: internal)}
      end)

      # the window remembers where the focus was, and gives it back when the dialog closes
      if on? != was?, do: out({:modal, if(on?, do: :open, else: :close)})
      :undefined
    end)

    # a popover is (or is no longer) showing
    def_fn(p, "__setPopover", fn this, args ->
      on? = truthy(arg(args, 0))

      update_node(this_nid(this), fn n ->
        internal = List.keydelete(n.internal, "@popover", 0)
        %{n | internal: if(on?, do: internal ++ [{"@popover", 1}], else: internal)}
      end)

      :undefined
    end)

    def_fn(p, "click", fn this, _ ->
      synthetic_click(this_nid(this))
      :undefined
    end)

    def_fn(p, "submit", fn this, _ ->
      submit_form(this_nid(this), nil)
      :undefined
    end)

    def_fn(p, "requestSubmit", fn this, args ->
      request_submit(this_nid(this), submitter_arg(arg(args, 0)))
      :undefined
    end)

    def_fn(p, "reset", fn this, _ ->
      nid = this_nid(this)

      if dispatch(nid, "reset", %{bubbles: true, cancelable: true}) != :prevented,
        do: reset_controls(nid)

      :undefined
    end)

    def_fn(p, "getBoundingClientRect", fn this, _ -> rect_object(this_nid(this)) end)

    def_fn(p, "getClientRects", fn this, _ ->
      case page_rect(this_nid(this)) do
        {_, _, w, h} when w == 0 and h == 0 -> new_array([])
        _ -> new_array([rect_object(this_nid(this))])
      end
    end)

    def_fn(p, "animate", fn _this, _ -> new_object([]) end)
  end

  defp submitter_arg({:obj, _} = o), do: nid_of(o)
  defp submitter_arg(_), do: nil

  # the submit event, then the submission unless a script stopped it
  defp request_submit(form, submitter) do
    if dispatch(form, "submit", %{"submitter" => wrap_or_null(submitter)}) == :ok,
      do: submit_form(form, submitter)
  end

  # `<form method="dialog">` closes its dialog (see `Browser.Modal`); any other goes to the window
  defp submit_form(form, submitter) do
    method =
      with s when s != nil <- submitter && get_attr(node(submitter), "formmethod") do
        s
      else
        _ -> get_attr(node(form), "method") || ""
      end

    if Str.downcase(method) == "dialog" do
      call_global("__dialogSubmit", [wrap(form), if(submitter, do: wrap(submitter), else: :null)])
    else
      out({:submit, form_index(form)})
    end
  end

  # ── activation behavior ────────────────────────────────────

  # `el.click()`: a click event that a script caused (a `PointerEvent`, with no position and
  # button 0) and the activation behavior. A disabled form control does nothing, and an
  # element that is in its own `click()` already does not click again.
  defp synthetic_click(nid) do
    n = node(nid)
    key = {:dom_clicking, nid}

    cond do
      n.kind == :element and n.tag in ~w(button input select textarea) and
          get_attr(n, "disabled") != nil ->
        :ok

      Process.get(key) ->
        :ok

      true ->
        Process.put(key, true)

        try do
          dispatch(nid, "click", %{
            "detail" => 0.0,
            "pointerId" => -1.0,
            bubbles: true,
            cancelable: true,
            composed: true,
            trusted: false,
            activate: true
          })
        after
          Process.delete(key)
        end
    end
  end

  # The element whose activation behavior a click runs: the target when it has one, else (for
  # an event that bubbles) the nearest element on the path that has one.
  defp activation_target([first | rest], bubbles) do
    cond do
      is_integer(first) and activation?(first) -> first
      bubbles -> Enum.find(rest, &(is_integer(&1) and activation?(&1)))
      true -> nil
    end
  end

  @activation_inputs ~w(checkbox radio submit image reset button file color)

  defp activation?(nid) do
    n = node(nid)

    n.kind == :element and
      case n.tag do
        t when t in ["a", "area"] -> get_attr(n, "href") != nil
        "input" -> type_of(n) in @activation_inputs
        t when t in ["button", "label"] -> true
        "summary" -> details_of_summary(nid) != nil
        _ -> false
      end
  end

  # the `<details>` that `nid` is the summary of (its first `<summary>` child), or nil
  defp details_of_summary(nid) do
    with p when p != nil <- node(nid).parent,
         %{kind: :element, tag: "details", kids: kids} <- node(p),
         ^nid <- Enum.find(kids, &match?(%{kind: :element, tag: "summary"}, node(&1))) do
      p
    else
      _ -> nil
    end
  end

  # The legacy-pre-activation behavior: a checkbox changes its state, a radio button is
  # checked, before the click event is dispatched. Gives what the canceled-activation behavior
  # restores.
  defp pre_activation(nid) do
    n = node(nid)

    if n.tag == "input" and get_attr(n, "disabled") == nil do
      case type_of(n) do
        "checkbox" ->
          old = checked_of(n)
          set_checked(nid, not old)
          {:checkbox, old}

        "radio" ->
          old = checked_of(n)
          prev = if not old, do: Enum.find(radio_group(nid), &checked_of(node(&1)))
          set_checked(nid, true)
          {:radio, old, prev}

        _ ->
          nil
      end
    end
  end

  # the legacy-canceled-activation behavior: a script canceled the click
  defp canceled_activation(nid, {:checkbox, old}),
    do: update_node(nid, &%{&1 | props: Map.put(&1.props, "checked", old)})

  defp canceled_activation(nid, {:radio, false, prev}) do
    update_node(nid, &%{&1 | props: Map.put(&1.props, "checked", false)})
    if prev != nil and prev in radio_group(nid), do: set_checked(prev, true)
  end

  defp canceled_activation(_nid, _pre), do: :ok

  # The activation behavior of `nid` (a click that no script canceled): a link is followed, a
  # checkbox or radio button fires `input` and `change`, a button submits or resets its form or
  # shows its popover, a label clicks its control, a summary opens or closes its details.
  defp activation(nid, target, pre) do
    n = node(nid)

    case n.tag do
      t when t in ["a", "area"] -> follow_hyperlink(nid)
      "label" -> label_activation(nid, target)
      "summary" -> toggle_details(details_of_summary(nid))
      _ when n.tag in ["button", "input"] -> control_activation(nid, n, pre)
      _ -> :ok
    end

    :ok
  end

  defp control_activation(nid, n, pre) do
    type = type_of(n)

    cond do
      get_attr(n, "disabled") != nil ->
        :ok

      n.tag == "input" and type in ["checkbox", "radio"] ->
        # (a radio button that was checked already did not change)
        if connected?(nid) and not match?({:radio, true, _}, pre) do
          dispatch(nid, "input", %{
            bubbles: true,
            cancelable: false,
            composed: true,
            class: "Event"
          })

          dispatch(nid, "change", %{bubbles: true, cancelable: false, composed: false})
        end

      true ->
        if get_attr(n, "popovertarget") != nil, do: call_global("__popoverInvoke", [wrap(nid)])

        case {type, form_of(nid)} do
          {_, nil} -> :ok
          {t, form} when t in ["submit", "image"] -> request_submit(form, nid)
          {"reset", form} -> reset_form_node(form)
          _ -> :ok
        end
    end
  end

  # `form.reset()`: the `reset` event, then the controls go back to their markup's values
  defp reset_form_node(form) do
    if dispatch(form, "reset", %{bubbles: true, cancelable: true}) != :prevented,
      do: reset_controls(form)
  end

  # A link that a script clicked: a `download` link saves, any other goes to its address (a
  # fragment of this page stays in the document, see `navigate_to/2`). A `javascript:`
  # address and a link that opens a new window (`target="_blank"`) do nothing: a click that
  # the user did not make cannot open a window.
  defp follow_hyperlink(nid) do
    n = node(nid)
    href = get_attr(n, "href")
    target = Str.downcase(get_attr(n, "target") || "")

    cond do
      not connected?(nid) -> :ok
      download(nid) -> :ok
      target not in ["", "_self", "_top", "_parent"] -> :ok
      href |> String.trim_leading() |> Str.downcase() |> String.starts_with?("javascript:") -> :ok
      follow_link_in(nid, href) == :frame -> :ok
      true -> in_realm(n.doc, fn -> navigate_to(resolve_url(href)) end)
    end
  end

  # A click on a label is a click on its control, unless it was on the control itself or on
  # interactive content in the label.
  defp label_activation(label, target) do
    control = labeled_control(label)

    on_interactive? =
      is_integer(target) and
        Enum.any?(
          Enum.take_while([target | ancestors(target)], &(&1 != label)),
          &(&1 == control or interactive?(node(&1)))
        )

    if control != nil and not on_interactive?, do: synthetic_click(control)
  end

  defp labelable?(%{kind: :element, tag: "input"} = n), do: type_of(n) != "hidden"

  defp labelable?(%{kind: :element, tag: t}),
    do: t in ~w(button meter output progress select textarea)

  defp labelable?(_n), do: false

  defp interactive?(%{kind: :element} = n) do
    case n.tag do
      "a" -> get_attr(n, "href") != nil
      t when t in ["audio", "video"] -> get_attr(n, "controls") != nil
      "img" -> get_attr(n, "usemap") != nil
      t when t in ~w(button details embed iframe label select textarea) -> true
      "input" -> type_of(n) != "hidden"
      _ -> false
    end
  end

  defp interactive?(_n), do: false

  # the control of a label: the element its `for` names, else the first labelable element in it
  defp labeled_control(label) do
    case get_attr(node(label), "for") do
      nil ->
        find_element(label, &labelable?/1)

      id ->
        root = List.last([label | ancestors(label)])

        case element_by_id(root, id) do
          nil -> nil
          c -> if labelable?(node(c)), do: c
        end
    end
  end

  defp toggle_details(nil), do: :ok

  defp toggle_details(details) do
    was_open = open_of(node(details))
    update_node(details, &%{&1 | props: Map.put(&1.props, "open", not was_open)})
    details_toggled(details, was_open)
  end

  # A checkbox's or radio button's checked state. A radio button that is checked unchecks the
  # others of its group.
  defp set_checked(nid, checked) do
    update_node(nid, &%{&1 | props: Map.put(&1.props, "checked", checked)})

    if checked and type_of(node(nid)) == "radio" do
      for other <- radio_group(nid),
          checked_of(node(other)),
          do: update_node(other, &%{&1 | props: Map.put(&1.props, "checked", false)})
    end

    :ok
  end

  # The other radio buttons of the group of `nid`: the same name, the same form (or none) and
  # the same tree.
  defp radio_group(nid) do
    n = node(nid)

    case get_attr(n, "name") do
      name when name in [nil, ""] ->
        []

      name ->
        form = form_of(nid)
        root = List.last([nid | ancestors(nid)])

        for el <- elements(root),
            el != nid,
            o = node(el),
            o.tag == "input",
            type_of(o) == "radio",
            get_attr(o, "name") == name,
            form_of(el) == form,
            do: el
    end
  end

  defp adjacent(nid, position, ids) do
    n = node(nid)

    case position do
      "beforebegin" ->
        if n.parent, do: insert_all(n.parent, ids, nid)

      "afterbegin" ->
        insert_all(nid, ids, List.first(n.kids))

      "beforeend" ->
        insert_all(nid, ids, nil)

      "afterend" ->
        if n.parent do
          ref = elem(siblings(nid), 1) |> List.first()
          insert_all(n.parent, ids, ref)
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
    case Process.get({:dom_open, st().doc}) do
      nil -> write_into_page(html)
      buf -> rewrite_document(buf <> html)
    end

    :undefined
  end

  # after `document.open()` what is written is the new content of the document
  defp rewrite_document(buf) do
    doc = st().doc
    Process.put({:dom_open, doc}, buf)

    kids =
      buf
      |> Browser.HTML.parse_document()
      |> build_all(doc)

    for k <- node(doc).kids, do: update_node(k, &%{&1 | parent: nil})
    update_node(doc, &%{&1 | kids: []})
    Enum.each(kids, &insert(doc, &1, nil))
  end

  defp write_into_page(html) do
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
  end

  defp install_document(p) do
    for name <- ~w(write writeln) do
      def_fn(p, name, fn _this, args ->
        text = Enum.map_join(args, "", &to_str/1)
        write_html(if name == "writeln", do: text <> "\n", else: text)
      end)
    end

    def_fn(p, "open", fn _this, _ ->
      # (a document that is still being parsed keeps what it has)
      if st().current_script == nil, do: rewrite_document("")
      :undefined
    end)

    def_fn(p, "close", fn _this, _ ->
      Process.delete({:dom_open, st().doc})
      :undefined
    end)

    def_fn(p, "getElementById", fn _this, args ->
      id = to_str(arg(args, 0))
      wrap_or_null(element_by_id(st().doc, id))
    end)

    def_fn(p, "createElement", fn _this, args ->
      tag = args |> arg(0) |> to_str() |> Str.downcase()

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

    def_fn(p, "createEvent", fn _this, args ->
      construct_event(create_event_class(Str.downcase(to_str(arg(args, 0)))), :undefined, [""])
    end)

    def_fn(p, "hasFocus", fn _this, _ -> true end)
  end

  # the interface that `document.createEvent(name)` makes (an unknown name makes an `Event`)
  defp create_event_class(name) do
    case name do
      n when n in ["uievent", "uievents"] -> "UIEvent"
      n when n in ["mouseevent", "mouseevents"] -> "MouseEvent"
      "customevent" -> "CustomEvent"
      "keyboardevent" -> "KeyboardEvent"
      "focusevent" -> "FocusEvent"
      "compositionevent" -> "CompositionEvent"
      "dragevent" -> "DragEvent"
      _ -> "Event"
    end
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

    # the path of the event while it is in dispatch (with the nodes of closed shadow trees
    # too), else empty
    def_fn(p, "composedPath", fn this, _ ->
      case Process.get({:dom_event_path, this}) do
        nil -> new_array([])
        path -> new_array(Enum.map(path, &target_obj/1))
      end
    end)

    # the old way to fill in an event made by `document.createEvent` (type, bubbles, cancelable,
    # then the extra arguments of each kind)
    init = fn extra ->
      fn this, args ->
        put(this, "type", to_str(arg(args, 0)))
        put(this, "bubbles", truthy(arg(args, 1)))
        put(this, "cancelable", truthy(arg(args, 2)))

        for {name, i} <- Enum.with_index(extra, 3), name != nil, do: put(this, name, arg(args, i))

        :undefined
      end
    end

    def_fn(p, "initEvent", init.([]))
    def_fn(p, "initCustomEvent", init.(["detail"]))
    def_fn(p, "initUIEvent", init.(["view", "detail"]))

    def_fn(
      p,
      "initMouseEvent",
      init.(
        ~w(view detail screenX screenY clientX clientY ctrlKey altKey shiftKey metaKey button relatedTarget)
      )
    )

    def_fn(
      p,
      "initKeyboardEvent",
      init.(["view", "key", "location", "ctrlKey", "altKey", "shiftKey", "metaKey"])
    )
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

    def_fn(sp, "item", fn this, args ->
      case Enum.at(style_decls(style_nid(this)), to_int(arg(args, 0))) do
        {k, _} -> k
        nil -> ""
      end
    end)

    def_fn(sp, "setProperty", fn this, args ->
      set_style(
        style_nid(this),
        Str.downcase(to_str(arg(args, 0))),
        to_str_or_empty(arg(args, 1))
      )

      :undefined
    end)

    def_fn(sp, "getPropertyValue", fn this, args ->
      name = Str.downcase(to_str(arg(args, 0)))

      if computed_style?(this) do
        case computed_get(style_nid(this), name) do
          {:ok, v} -> v
          _ -> ""
        end
      else
        style_decls(style_nid(this))
        |> List.keyfind(name, 0)
        |> then(&if(&1, do: elem(&1, 1), else: ""))
      end
    end)

    def_fn(sp, "removeProperty", fn this, args ->
      nid = style_nid(this)
      prop = Str.downcase(to_str(arg(args, 0)))
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

  defp style_nid({:obj, id}) do
    case deref(id) do
      %{host: {__MODULE__, {:style, nid}}} -> nid
      %{host: {__MODULE__, {:style, nid, :computed}}} -> nid
      _ -> nil
    end
  end

  defp computed_style?({:obj, id}),
    do: match?(%{host: {__MODULE__, {:style, _, :computed}}}, deref(id))

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
    # (`delete` and `defineProperty` leave these, see `Browser.JS.Global.define_var/2`)
    fixed = Process.get(:js_global_fixed) || MapSet.new()

    Process.put(
      :js_global_fixed,
      MapSet.union(fixed, MapSet.new(Browser.JS.Global.unforgeable()))
    )

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
    grad_proto = new_object([])
    install_canvas_gradient(grad_proto)
    Process.put(:canvas_grad_proto, grad_proto)

    ctor(scope, "CanvasGradient", grad_proto, fn _, _ ->
      throw_error("TypeError", "Illegal constructor")
    end)

    install_path2d(scope)

    ctor(scope, "CanvasRenderingContext2D", ctx_proto, fn _, _ ->
      throw_error("TypeError", "Illegal constructor")
    end)

    ctor(scope, "Text", text, fn _, _ -> :undefined end)
    ctor(scope, "Document", document, fn _, _ -> :undefined end)

    install_event_classes(scope, event)

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
      registered(Str.downcase(to_str(arg(args, 0)))) || :undefined
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
        aux_host({:style, nid_of(el), :computed}, :style)
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
