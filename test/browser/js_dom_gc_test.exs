defmodule Browser.JS.DOMGCTest do
  @moduledoc """
  The JS collector frees the nodes that nothing can reach any more, with their wrappers,
  listeners and index entries (see "the JS collector and the node table" in
  `Browser.JS.DOM`). A node that a script can still reach stays, with the same wrapper, its
  own properties, its listeners and its whole tree.
  """
  use ExUnit.Case, async: true
  alias Browser.JS.{Builtins, GC, Interp, Parser, Runtime}

  # Runs `fun` in a page process made of `body`. The ids of the first nodes are small
  # numbers, and the natives hold small numbers (tables of characters, sizes), which the
  # collector reads as node ids (see `Browser.JS.GC.push_nids/3`). So the nodes of a test get
  # ids above them.
  defp page(body \\ "", fun) do
    Task.async(fn ->
      {raw, _} = "<body>#{body}</body>" |> Browser.HTML.parse() |> Browser.Forms.index()
      Runtime.boot(raw, %{url: "http://t.test/", width: 800, height: 600})
      js("for (let i = 0; i < 3000; i++) document.createTextNode('')")
      GC.collect()
      fun.()
    end)
    |> Task.await(60_000)
  end

  # runs `src`; gives its value as a string
  defp js(src) do
    {:ok, p} = Parser.parse("String(eval(#{inspect(src)}))")

    try do
      Interp.run_program(p)
    catch
      {:js_error, v} -> flunk("JS error: " <> Runtime.describe(v))
    end
  end

  defp st, do: Process.get(:dom)
  defp node_count, do: map_size(st().nodes)

  # After a collect, no table of the state and no process key names a node that left the
  # node table.
  defp assert_clean do
    s = st()
    in? = &is_map_key(s.nodes, &1)

    for {k, _} <- s.wrappers, is_integer(k), do: assert(in?.(k), "wrapper of #{k}")

    for {{:aux, {kind, nid}}, _} <- s.wrappers,
        kind in [:classlist, :style, :dataset],
        do: assert(in?.(nid), "aux #{kind} of #{nid}")

    for {k, _} <- s.listeners, is_integer(k), do: assert(in?.(k), "listeners of #{k}")
    for {_, l} <- s.ids, nid <- l, do: assert(in?.(nid), "id index #{nid}")
    for {_, vals} <- s.aidx, {_, set} <- vals, {nid, _} <- set, do: assert(in?.(nid))
    for {nid, _} <- s.iframes, do: assert(in?.(nid), "iframe #{nid}")
    for nid <- s.ce_done, do: assert(in?.(nid), "ce_done #{nid}")

    for {k, _} <- Process.get(),
        is_tuple(k) and tuple_size(k) >= 2 and
          elem(k, 0) in [:canvas, :canvas_ctx, :inline_handler, :dom_frame_tok],
        do: assert(in?.(elem(k, 1)), "process key #{inspect(k)}")

    # (each node that a link names is in the table: no live tree lost a part)
    for {_, n} <- s.nodes,
        l <- [n.parent, n.shost, n.shadow, n.content, n.doc | n.kids],
        l,
        do: assert(in?.(l), "link to #{l}")
  end

  defp timers, do: Builtins.run_timers(fn v -> throw({:uncaught, v}) end)

  # the node `nid` and the nodes below it (in shadow roots and template contents too)
  defp tree(nid) do
    n = st().nodes[nid]
    [nid | Enum.flat_map(n.kids ++ List.wrap(n.content) ++ List.wrap(n.shadow), &tree/1)]
  end

  # the node id of the element with the id `id` (in the id index)
  defp nid(id) do
    [n] = Map.fetch!(st().ids, id)
    n
  end

  test "a removed tree that nothing holds leaves the node table, with its wrappers and listeners" do
    page(fn ->
      base = node_count()

      js("""
      var list = document.createElement('ul');
      document.body.appendChild(list);
      for (let i = 0; i < 50; i++) {
        const li = document.createElement('li');
        li.id = 'x' + i;
        li.setAttribute('data-k', 'v' + i);
        li.textContent = 'item ' + i;
        li.addEventListener('click', () => {});
        li.classList.add('a');
        li.style.color = 'red';
        list.appendChild(li);
      }
      document.querySelector('[data-k="v3"]').id
      """)

      assert node_count() == base + 101
      li = nid("x7")
      {:obj, w} = st().wrappers[li]
      assert st().listeners[li] != nil
      assert is_map_key(st().wrappers, {:aux, {:classlist, li}})

      # (all of them are in the document)
      GC.collect()
      assert node_count() == base + 101
      assert is_map(:erlang.get(w))

      js("list.remove(); list = null")
      GC.collect()
      assert node_count() == base
      refute is_map_key(st().nodes, li)
      refute is_map_key(st().wrappers, li)
      refute is_map_key(st().wrappers, {:aux, {:classlist, li}})
      refute is_map_key(st().wrappers, {:aux, {:style, li}})
      refute is_map_key(st().listeners, li)
      refute is_map_key(st().ids, "x7")
      assert :erlang.get(w) == :undefined
      assert st().aidx |> Map.get("data-k", %{}) |> map_size() == 0

      assert js("document.getElementById('x7') + ' ' + document.querySelector('[data-k=\"v3\"]')") ==
               "null null"
    end)
  end

  test "a few dead nodes among many live ones leave the indexes" do
    page(fn ->
      js("""
      for (let i = 0; i < 40; i++) {
        const p = document.createElement('p');
        p.id = 'p' + i;
        p.setAttribute('data-k', 'v' + (i % 4));
        document.body.appendChild(p);
      }
      document.querySelectorAll('[data-k="v1"]').length
      """)

      base = node_count()
      js("for (let i = 0; i < 40; i += 8) document.getElementById('p' + i).remove()")
      GC.collect()
      assert node_count() == base - 5
      refute is_map_key(st().ids, "p8")
      assert is_map_key(st().ids, "p9")

      assert js("""
             [document.getElementById('p8'), document.getElementById('p9').id,
              document.querySelectorAll('[data-k="v0"]').length,
              document.querySelectorAll('[data-k="v1"]').length].join()
             """) == ",p9,5,10"
    end)
  end

  test "a removed node that a script holds stays: the same wrapper, its properties and listeners" do
    page(fn ->
      js("""
      var kept = document.createElement('div');
      kept.id = 'k';
      kept.expando = { n: 1 };
      kept.innerHTML = '<span>a</span><b>b</b>';
      var fired = 0;
      kept.addEventListener('click', () => fired++);
      kept.onclick = () => fired += 10;
      document.body.appendChild(kept);
      kept.remove()
      """)

      k = nid("k")
      w = st().wrappers[k]
      all = tree(k)
      assert length(all) == 5
      GC.collect()
      assert Enum.all?(all, &is_map_key(st().nodes, &1))
      assert st().wrappers[k] == w

      assert js("""
             document.body.appendChild(kept);
             var same = document.getElementById('k') === kept && document.body.lastChild === kept;
             kept.click();
             [same, kept.expando.n, fired, kept.firstChild.tagName, kept.childNodes.length].join()
             """) == "true,1,11,SPAN,2"
    end)
  end

  # Each holder is the only path to the removed node: the node, its tree and its listener
  # stay, and the node is the same object.
  @holders [
    {"a variable", "var h = n", "h"},
    {"an array", "var h = [1, n]", "h[1]"},
    {"an object", "var h = { a: { b: n } }", "h.a.b"},
    {"a closure", "var h = (() => { const m = n; return () => m })()", "h()"},
    {"a Map key", "var h = new Map([[n, 1]])", "[...h.keys()][0]"},
    {"a Set", "var h = new Set([n])", "[...h][0]"},
    {"a NodeList of childNodes", "var h = wrap.childNodes", "h[0]"},
    {"a querySelectorAll list", "var h = wrap.querySelectorAll('section')", "h[0]"},
    {"a listener of a live node",
     "const m = n; document.body.addEventListener('x', () => { window.got = m })",
     "(document.body.dispatchEvent(new Event('x')), window.got)"},
    {"a timer", "const m = n; setTimeout(() => { window.got = m }, 5)", "(window.got)"},
    {"a promise reaction", "const m = n; Promise.resolve().then(() => { window.got = m })",
     "(window.got)"},
    {"a TreeWalker", "var h = document.createTreeWalker(wrap)", "h.root.firstChild"},
    # (a range in the document moves out of a node that leaves it, so this one is made in the
    # tree once the tree has left)
    {"a Range", "wrap.remove(); var h = document.createRange(); h.selectNodeContents(n)",
     "h.startContainer"},
    {"an event",
     "var h; n.addEventListener('y', e => { h = e }); n.dispatchEvent(new Event('y'))",
     "h.target"},
    {"its classList", "var h = n.classList", {"h.contains('c')", "true"}},
    {"its style", "var h = n.style", {"h.color", "red"}},
    {"its dataset", "var h = n.dataset", {"h.x", "1"}},
    {"a microtask", "const m = n; queueMicrotask(() => { window.got = m })", "(window.got)"},
    {"an animation frame", "const m = n; requestAnimationFrame(() => { window.got = m })",
     "(window.got)"},
    {"an IntersectionObserver",
     "new IntersectionObserver(es => { window.got = es[0].target }).observe(n)", "(window.got)"},
    {"the value of a WeakMap with a live key", "var h = new WeakMap([[document.body, { n }]])",
     "h.get(document.body).n"},
    {"a history state", "history.pushState({ n }, '')", "history.state.n"},
    {"a property of a live node", "document.body.held = { n }", "document.body.held.n"},
    {"a property of the window", "window.held = [n]", "window.held[0]"}
  ]

  for {name, hold, back} <- @holders do
    test "a removed node held by #{name} stays" do
      hold = unquote(hold)
      back = unquote(back)

      page(fn ->
        js("""
        var wrap = document.createElement('div');
        var n = document.createElement('section');
        n.id = 'held';
        n.className = 'c';
        n.dataset.x = '1';
        n.style.color = 'red';
        n.mark = 7;
        n.innerHTML = '<i>a</i><i>b</i>';
        var clicks = 0;
        n.addEventListener('click', () => clicks++);
        wrap.appendChild(n);
        document.body.appendChild(wrap);
        window.n2 = n;
        #{hold};
        wrap.remove();
        wrap = null;
        n = null;
        window.n2 = null
        """)

        held = nid("held")
        w = st().wrappers[held]
        GC.collect()
        assert is_map_key(st().nodes, held)
        assert st().wrappers[held] == w
        assert_clean()
        timers()
        Browser.JS.Promise.run_microtasks()

        check_back(back)
      end)
    end
  end

  # (only the classList, style or dataset object holds the node)
  defp check_back({check, value}), do: assert(js(check) == value)

  defp check_back(back) do
    assert js("""
           var r = #{back};
           document.body.appendChild(r);
           r.click();
           [r === document.getElementById('held'), r.mark, r.className, r.dataset.x,
            r.style.color, r.childNodes.length, clicks, r.parentNode === document.body].join()
           """) == "true,7,c,1,red,2,1,true"
  end

  test "a detached tree held through one node keeps all of its nodes" do
    page(fn ->
      js("""
      var outer = document.createElement('div');
      outer.innerHTML = '<ul><li id=a>a</li><li id=b><i id=deep>x</i></li></ul><p id=side>s</p>';
      outer.id = 'outer';
      document.body.appendChild(outer);
      var deep = document.getElementById('deep');
      outer.remove();
      outer = null
      """)

      all = tree(nid("outer"))
      assert length(all) == 9
      GC.collect()
      assert Enum.all?(all, &is_map_key(st().nodes, &1))
      base = node_count()

      assert js("""
             var t = deep.parentNode.parentNode.parentNode;
             [t.tagName, t.querySelector('#side').textContent, t.querySelectorAll('li').length].join()
             """) == "DIV,s,2"

      js("deep = null; t = null")
      GC.collect()
      assert node_count() == base - 9
      refute Enum.any?(all, &is_map_key(st().nodes, &1))
    end)
  end

  test "a template's content and a shadow root keep what they need" do
    page(fn ->
      js("""
      var tpl = document.createElement('template');
      tpl.innerHTML = '<b id=t1>t</b>';
      var frag = tpl.content;
      var host = document.createElement('div');
      var root = host.attachShadow({ mode: 'open' });
      root.innerHTML = '<p>in</p>';
      document.body.append(tpl, host);
      var hold = root;
      tpl.remove(); host.remove();
      tpl = null; host = null; root = null
      """)

      GC.collect()
      # (the content of a template does not hold the template; a shadow root holds its host)
      assert js(
               "[frag.firstChild.id, hold.host.tagName, hold.host.shadowRoot === hold, hold.firstChild.textContent].join()"
             ) ==
               "t1,DIV,true,in"

      base = node_count()
      js("frag = null; hold = null")
      GC.collect()
      # the fragment and its <b> and text, the host, the shadow root, its <p> and text
      assert node_count() == base - 7
    end)
  end

  test "a canvas and its context go together" do
    page(fn ->
      js("""
      var c = document.createElement('canvas');
      var ctx = c.getContext('2d');
      ctx.fillRect(0, 0, 4, 4);
      c = null
      """)

      [canvas] = for {{:canvas_ctx, n}, _} <- Process.get(), n > 3000, do: n
      GC.collect()
      # (the context holds the canvas)
      assert is_map_key(st().nodes, canvas)
      assert js("ctx.canvas.getContext('2d') === ctx") == "true"

      js("ctx = null")
      GC.collect()
      refute is_map_key(st().nodes, canvas)
      assert Process.get({:canvas_ctx, canvas}) == nil
      assert Process.get({:canvas, canvas}) == nil
    end)
  end

  test "a custom element that leaves is forgotten as made" do
    page(fn ->
      js("""
      customElements.define('x-gc', class extends HTMLElement {});
      var e = document.createElement('x-gc');
      document.body.appendChild(e);
      e.id = 'ce';
      e.remove();
      e = null
      """)

      ce = nid("ce")
      assert MapSet.member?(st().ce_done, ce)
      GC.collect()
      refute MapSet.member?(st().ce_done, ce)
      refute is_map_key(st().nodes, ce)
    end)
  end

  test "a frame's document stays, and its nodes that leave are freed" do
    page(fn ->
      js("""
      var f = document.createElement('iframe');
      f.srcdoc = '<p id=fp>frame</p><ul id=fl><li>1</li></ul>';
      document.body.appendChild(f)
      """)

      timers()
      GC.collect()

      assert js("""
             var d = f.contentDocument;
             var list = d.getElementById('fl');
             list.remove();
             list = null;
             [d.getElementById('fp').textContent, d.body.childNodes.length].join()
             """) == "frame,1"

      doc = st().frames |> Map.values() |> hd()
      in_frame = fn -> Enum.count(st().nodes, fn {_, n} -> n.doc == doc end) end
      before = in_frame.()
      f = Map.keys(st().frames) |> hd()
      GC.collect()
      # the list, its item and the item's text
      assert in_frame.() == before - 3
      assert js("f.contentDocument === d && d.getElementById('fp').ownerDocument === d") == "true"
      assert st().frames[f] == doc

      # (a frame that leaves the document goes with its document)
      js("f.remove(); f = null; d = null")
      GC.collect()
      assert in_frame.() == 0
      refute is_map_key(st().nodes, f)
      refute is_map_key(st().iframes, f)
    end)
  end

  test "the function of a handler attribute goes with its node" do
    page(fn ->
      js("""
      var b = document.createElement('button');
      b.setAttribute('onclick', 'window.hits = (window.hits || 0) + 1');
      b.id = 'btn';
      var f = b.onclick;
      b.click();
      0
      """)

      btn = nid("btn")
      assert [_] = for({{:inline_handler, ^btn, _, _} = k, _} <- Process.get(), do: k)
      GC.collect()
      assert js("b.onclick === f && window.hits === 1") == "true"

      js("b = null; f = null")
      GC.collect()
      refute is_map_key(st().nodes, btn)
      assert for({{:inline_handler, ^btn, _, _} = k, _} <- Process.get(), do: k) == []
    end)
  end

  # A native can hold a node id in its environment (as a plain integer): the node stays
  # while the native is reachable.
  test "a native that holds a node id keeps the node" do
    page(fn ->
      js("var e = document.createElement('kbd'); e.id = 'kb'; e = null")
      kb = nid("kb")
      held = Interp.native("held", fn _this, _args -> Browser.JS.DOM.node_data(kb).tag end)
      Process.put({:dom_gc_test, 1}, held)
      GC.collect()
      assert Interp.call(held, :undefined, []) == "kbd"
      assert is_map_key(st().nodes, kb)

      Process.delete({:dom_gc_test, 1})
      GC.collect()
      refute is_map_key(st().nodes, kb)
    end)
  end

  test "a node whose id only a number holds is freed" do
    page(fn ->
      js("""
      var e = document.createElement('em');
      e.id = 'num';
      document.body.appendChild(e);
      e.remove();
      e = null
      """)

      n = nid("num")
      # (a JS number with the value of the node id is not a reference to the node)
      js("var num = #{n}; var nums = [#{n}, #{n} + 0.0]")
      GC.collect()
      refute is_map_key(st().nodes, n)
    end)
  end

  # The wrapper of a live node is not a root: the walk finds it when it finds the node. What
  # it holds can make a detached tree live, and what that tree holds can make one more live.
  test "a chain of detached nodes from a live node through wrappers and listeners stays" do
    page(fn ->
      js("""
      (() => {
        const a = document.createElement('p'); a.id = 'ca';
        const b = document.createElement('p'); b.id = 'cb';
        const c = document.createElement('canvas'); c.id = 'cc'; c.mark = 3;
        const w = document.createElement('p'); w.id = 'cw';
        document.body.expando = { a };
        a.addEventListener('x', () => { window.gotB = b });
        b.onclick = () => { window.gotC = c };
        // (the context of a canvas is kept by the canvas: a property on it holds one more)
        c.getContext('2d').held = w;
      })()
      """)

      ids = for i <- ~w(ca cb cc cw), do: nid(i)
      GC.collect()
      assert Enum.all?(ids, &is_map_key(st().nodes, &1))
      assert_clean()

      assert js("""
             var a = document.body.expando.a;
             a.dispatchEvent(new Event('x'));
             gotB.click();
             [a.id, gotB.id, gotC.id, gotC.mark, gotC.getContext('2d').held.id,
              document.body.expando.a === a].join()
             """) == "ca,cb,cc,3,cw,true"

      js("document.body.expando = null; gotB = gotC = a = null")
      GC.collect()
      refute Enum.any?(ids, &is_map_key(st().nodes, &1))
      assert_clean()
    end)
  end

  test "the nodes of a document stay when no script holds them, with a closed shadow root and a template" do
    page(
      "<div id=host></div><template id=t><b id=tb>x</b></template><ul id=l><li>1</li></ul>",
      fn ->
        js("""
        document.getElementById('host').attachShadow({ mode: 'closed' }).innerHTML = '<i id=sh>s</i>';
        document.getElementById('host').addEventListener('x', () => { window.fired = 1 });
        0
        """)

        doc = st().main
        all = tree(doc)
        host = nid("host")
        assert st().nodes[host].shadow in all
        assert st().nodes[nid("t")].content in all
        # (no wrapper of the document's nodes is held by a script now)
        js("for (let i = 0; i < 100; i++) document.createElement('div')")
        GC.collect()
        GC.collect()
        assert Enum.all?(all, &is_map_key(st().nodes, &1))
        assert tree(doc) == all
        assert_clean()

        assert js("""
               document.getElementById('host').dispatchEvent(new Event('x'));
               [document.getElementById('t').content.firstChild.id,
                document.getElementById('l').firstChild.textContent, window.fired].join()
               """) == "tb,1,1"
      end
    )
  end

  test "a second collect frees no more, and an id that two elements had finds the live one" do
    page(fn ->
      js("""
      var d1 = document.createElement('p'); d1.id = 'dup'; d1.textContent = 'old';
      var d2 = document.createElement('p'); d2.id = 'dup'; d2.textContent = 'new';
      document.body.append(d1, d2);
      d1.remove();
      d1 = d2 = null
      """)

      assert length(st().ids["dup"]) == 2
      GC.collect()
      assert [_] = st().ids["dup"]
      assert_clean()
      n = node_count()
      wrappers = map_size(st().wrappers)
      GC.collect()
      assert node_count() == n
      assert map_size(st().wrappers) == wrappers

      assert js("""
             [document.getElementById('dup').textContent, document.querySelector('#dup').textContent,
              document.querySelectorAll('#dup').length].join()
             """) == "new,new,1"
    end)
  end

  test "a page and a frame hold each other's detached nodes" do
    page(fn ->
      js("""
      var f = document.createElement('iframe');
      f.srcdoc = '<p id=fp>frame</p>';
      document.body.appendChild(f)
      """)

      timers()

      js("""
      var fd = f.contentDocument;
      var fp = fd.getElementById('fp');
      fp.mark = 'f';
      fp.addEventListener('x', () => { window.fx = 1 });
      fp.remove();
      // (the frame's own global scope holds a node of the page)
      var pp = document.createElement('p'); pp.id = 'pp'; pp.mark = 'p';
      f.contentWindow.held = pp;
      window.heldF = fp;
      fp = pp = fd = null;
      0
      """)

      ids = [nid("fp"), nid("pp")]
      GC.collect()
      assert Enum.all?(ids, &is_map_key(st().nodes, &1))
      assert_clean()

      assert js("""
             heldF.dispatchEvent(new Event('x'));
             [heldF.mark, heldF.ownerDocument === f.contentDocument, window.fx,
              f.contentWindow.held.mark].join()
             """) == "f,true,1,p"

      # (the frame goes when its element leaves; what the page holds of it is gone with it)
      js("f.remove(); f = null; heldF = null")
      GC.collect()
      refute is_map_key(st().nodes, nid_or_nil("fp"))
      refute is_map_key(st().nodes, hd(ids))
      assert st().frames == %{}
      assert_clean()
    end)
  end

  test "a frame's nodes that a collect freed, then the frame's removal" do
    page(fn ->
      js("""
      var f = document.createElement('iframe');
      f.srcdoc = '<ul id=fl><li id=fi>1</li></ul><p id=fp>p</p>';
      document.body.appendChild(f)
      """)

      timers()
      js("f.contentDocument.getElementById('fl').remove(); 0")
      GC.collect()
      refute is_map_key(st().ids, "fi")
      assert_clean()
      js("f.remove(); 0")
      refute is_map_key(st().ids, "fp")
      GC.collect()
      assert_clean()
      assert js("f.contentDocument") == "null"
      # (the frame loads again when its element goes back)
      js("document.body.appendChild(f); 0")
      timers()
      assert js("f.contentDocument.getElementById('fp').textContent") == "p"
      assert_clean()
    end)
  end

  test "a custom element that leaves, held by a script, keeps its instance and comes back" do
    page(fn ->
      js("""
      var calls = [];
      customElements.define('x-keep', class extends HTMLElement {
        constructor() { super(); this.made = (window.made = (window.made || 0) + 1); }
        connectedCallback() { calls.push('in' + this.made); }
        disconnectedCallback() { calls.push('out' + this.made); }
      });
      var e = document.createElement('x-keep');
      e.id = 'xk';
      document.body.appendChild(e);
      e.remove();
      window.keepIt = [e];
      e = null
      """)

      GC.collect()
      assert is_map_key(st().nodes, nid("xk"))
      assert MapSet.member?(st().ce_done, nid("xk"))

      assert js("""
             var e = keepIt[0];
             document.body.appendChild(e);
             [e.made, window.made, calls.filter(c => c[0] == 'i').join(' '), e instanceof HTMLElement].join()
             """) == "1,1,in1 in1,true"
    end)
  end

  test "a detached form keeps its controls" do
    page(fn ->
      js("""
      var form = document.createElement('form');
      form.innerHTML = '<input name=a value=1><select name=s><option>x</option></select>';
      document.body.appendChild(form);
      form.remove();
      window.kept = form;
      form = null
      """)

      GC.collect()
      assert_clean()

      assert js("""
             [kept.querySelectorAll('input, select').length, kept.querySelector('[name=a]').value,
              kept.querySelector('select').value, kept.querySelector('select').form === kept].join()
             """) == "2,1,x,true"
    end)
  end

  test "a module's own variable keeps a node" do
    page(fn ->
      {:ok, p} =
        Parser.parse(
          """
          const n = document.createElement('aside');
          n.id = 'mod';
          n.mark = 4;
          export function get() { return n; }
          """,
          module: true
        )

      Browser.JS.Modules.run({:inline, :gc_test}, "http://t.test/", p, Runtime.loader())
      timers()
      GC.collect()
      assert is_map_key(st().nodes, nid("mod"))
      ns = Browser.JS.Modules.namespace({:inline, :gc_test})
      got = Interp.call(Interp.get(ns, "get"), :undefined, [])
      assert Interp.get(got, "mark") == 4
    end)
  end

  # What the session does with the page after a collect: it reads the tree again, and it
  # sends the pointer from an element that a script took away and that nothing holds.
  test "the export of the tree and a hover after a collect" do
    page(fn ->
      # (the nodes of the page's markup have small ids: they are made here, after the others)
      js("document.body.innerHTML = '<p id=a>a</p><p id=b>b</p>'")
      raw = Browser.JS.DOM.to_raw()
      layout_num = fn id -> st().nodes[nid(id)].internal |> List.keyfind("@nid", 0) |> elem(1) end
      {a, b} = {layout_num.("a"), layout_num.("b")}

      js("""
      var hits = [];
      document.getElementById('b').addEventListener('mouseover', () => hits.push('over-b'));
      var x = document.getElementById('a');
      x.remove();
      x = null;
      0
      """)

      gone = nid("a")
      GC.collect()
      refute is_map_key(st().nodes, gone)
      Browser.JS.DOM.hover(a, b)
      assert js("hits.join()") == "over-b"

      raw2 = Browser.JS.DOM.to_raw()
      assert length(raw2) == length(raw)
      refute inspect(raw2) =~ ~s({"id", "a"})
      Browser.JS.DOM.sync_cids(raw2)
      assert_clean()
    end)
  end

  # (the timer of the `load` event holds the image's node id in the environment of a native)
  test "an image that nothing holds stays until its load event, and hears it" do
    page(fn ->
      js("""
      (() => {
        const img = new Image();
        img.id = 'im';
        img.onload = () => { window.loaded = img.id };
        img.src = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
      })()
      """)

      im = nid("im")
      GC.collect()
      assert is_map_key(st().nodes, im)
      timers()
      assert js("window.loaded") == "im"
      GC.collect()
      refute is_map_key(st().nodes, im)
      assert_clean()
    end)
  end

  # (the focus is a root: the editing host that has it hears `blur` when the session takes
  # the focus away, also after a script took it out of the document)
  test "the focused editing host stays after it leaves the document" do
    page(fn ->
      js("""
      (() => {
        const ed = document.createElement('div');
        ed.id = 'ed';
        ed.setAttribute('contenteditable', 'true');
        ed.addEventListener('blur', () => { window.blurred = (window.blurred || 0) + 1 });
        document.body.appendChild(ed);
        ed.focus();
        ed.remove();
      })()
      """)

      ed = nid("ed")
      assert st().focus_ed == ed
      GC.collect()
      assert is_map_key(st().nodes, ed)
      Browser.JS.DOM.ed_blur()
      assert js("window.blurred") == "1"
      GC.collect()
      refute is_map_key(st().nodes, ed)
      assert_clean()
    end)
  end

  defp nid_or_nil(id) do
    case st().ids do
      %{^id => [n]} -> n
      _ -> nil
    end
  end
end
