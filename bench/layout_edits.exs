# Usage: mix run --no-start bench/layout_edits.exs [pages...]
# The edit-differential check of the kept layout memo (Browser.Layout.layout_kept/6): each page
# in bench/pages/ gets a series of edits to its tree, as a script makes them (a text changes,
# grows or empties, an element is hidden or shown, an element is added or removed, the window
# width changes) or as typing makes them (a field gets a new value: `Page.render/2`, which keeps
# every element the edit did not change, so that their ops are taken from the layout before).
# After each edit the page is laid out from the memo of the layout before (from a copy of the
# tree, as the layout worker gets it) and also afresh with the ops as a flat list (no spans, no
# fragments), and the two results must be the same (references and paint orders numbered).
#
# Prints the edits and differences per page and exits with status 1 when a difference is found.
# EDITS=40 sets the number of edits per page; SEED=1 the random seed. Uses a stub measurer.
Application.ensure_all_started(:inets)
Application.ensure_all_started(:ssl)
alias Browser.{Forms, Layout, Page}

measure = fn t, _s -> String.length(t) * 7 end
edits = String.to_integer(System.get_env("EDITS", "40"))
seed = String.to_integer(System.get_env("SEED", "1"))
dir = Path.join(__DIR__, "pages")

files =
  case System.argv() do
    [] -> dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".html")) |> Enum.sort()
    names -> names
  end

env = fn w -> %{Browser.Style.default_env() | width: w} end

# the k-th node (depth first, from 0) for which `pick?` is true, replaced by `fun.(node)`
# (a list of nodes); -> {nodes, k left}
edit_at = fn nodes, k, pick?, fun ->
  walk = fn walk, nodes, k ->
    Enum.flat_map_reduce(nodes, k, fn node, k ->
      cond do
        k < 0 ->
          {[node], k}

        pick?.(node) and k == 0 ->
          {fun.(node), -1}

        true ->
          k = if pick?.(node), do: k - 1, else: k

          case node do
            {:element, tag, attrs, kids} ->
              {kids, k} = walk.(walk, kids, k)
              {[{:element, tag, attrs, kids}], k}

            _ ->
              {[node], k}
          end
      end
    end)
  end

  elem(walk.(walk, nodes, k), 0)
end

count = fn nodes, pick? ->
  walk = fn walk, nodes ->
    Enum.reduce(nodes, 0, fn node, n ->
      n = if pick?.(node), do: n + 1, else: n

      case node do
        {:element, _, _, kids} -> n + walk.(walk, kids)
        _ -> n
      end
    end)
  end

  walk.(walk, nodes)
end

text? = &match?({:text, _}, &1)
box? = &match?({:element, tag, _, _} when tag in ~w(div p span li td a h1 h2 h3 section), &1)

toggle_hidden = fn {:element, tag, attrs, kids} ->
  attrs =
    case List.keyfind(attrs, "hidden", 0) do
      nil -> [{"hidden", ""} | attrs]
      _ -> List.keydelete(attrs, "hidden", 0)
    end

  [{:element, tag, attrs, kids}]
end

# -> {name, raw, width}
edit = fn raw, width, i ->
  texts = max(count.(raw, text?), 1)
  boxes = max(count.(raw, box?), 1)

  case :rand.uniform(7) do
    1 ->
      {"text changes",
       edit_at.(raw, :rand.uniform(texts) - 1, text?, fn _ -> [{:text, "edit #{i}"}] end), width}

    2 ->
      {"text grows",
       edit_at.(raw, :rand.uniform(texts) - 1, text?, fn {:text, t} ->
         [{:text, t <> String.duplicate(" more words", :rand.uniform(9))}]
       end), width}

    3 ->
      {"text empties", edit_at.(raw, :rand.uniform(texts) - 1, text?, fn _ -> [{:text, ""}] end),
       width}

    4 ->
      {"hidden toggles", edit_at.(raw, :rand.uniform(boxes) - 1, box?, toggle_hidden), width}

    5 ->
      {"element added",
       edit_at.(raw, :rand.uniform(boxes) - 1, box?, fn node ->
         [node, {:element, "div", [], [{:text, "added #{i}"}]}]
       end), width}

    6 ->
      {"element removed", edit_at.(raw, :rand.uniform(boxes) - 1, box?, fn _ -> [] end), width}

    7 ->
      {"width changes", raw, Enum.random([700, 1000, 1280] -- [width])}
  end
end

:rand.seed(:exsss, {seed, seed, seed})

failed =
  for file <- files, reduce: 0 do
    failed ->
      page =
        Page.build(
          File.read!(Path.join(dir, file)),
          "file://" <> Path.join(dir, file),
          env.(1000)
        )

      opts = fn p -> [images: %{}, svg_defs: p.svg_defs, boxes: true, scrollers: true] end
      {_, _, memo} = Layout.layout_kept(page.nodes, 1000, measure, 768, opts.(page), nil)

      {_, _, _, kinds, diffs} =
        Enum.reduce(1..edits, {page, 1000, memo, %{}, []}, fn i,
                                                              {page, width, memo, kinds, diffs} ->
          fields = page.forms.controls |> Map.values() |> Enum.filter(&Forms.editable?/1)

          {name, page, width} =
            if fields != [] and :rand.uniform(3) == 1 do
              field = Enum.random(fields)
              value = String.duplicate("typed ", :rand.uniform(6))

              {"field typed in",
               Page.render(page, Forms.put(page.form_state, field.cid, value: value)), width}
            else
              {name, raw, width} = edit.(page.raw, width, i)
              {name, Page.from_raw(page, raw, env.(width)), width}
            end

          # (a copy, as the layout worker gets it in a message)
          copy = :erlang.binary_to_term(:erlang.term_to_binary(page.nodes))
          {items, height, memo} = Layout.layout_kept(copy, width, measure, 768, opts.(page), memo)

          {fresh, fresh_height} =
            Layout.layout(page.nodes, width, measure, 768, [spans: false] ++ opts.(page))
          same? = height == fresh_height and Layout.memo_norm(items) == Layout.memo_norm(fresh)
          diffs = if same?, do: diffs, else: ["edit #{i} (#{name})" | diffs]
          {page, width, memo, Map.update(kinds, name, 1, &(&1 + 1)), diffs}
        end)

      summary = kinds |> Enum.sort() |> Enum.map_join(", ", fn {k, n} -> "#{n} #{k}" end)
      IO.puts("#{String.pad_trailing(file, 14)}#{length(diffs)} differences (#{summary})")
      for d <- Enum.reverse(diffs), do: IO.puts("    differs after #{d}")
      failed + length(diffs)
  end

if failed > 0 do
  IO.puts("\n#{failed} edits gave another layout from the kept memo than afresh")
  System.halt(1)
end
