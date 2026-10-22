defmodule Browser.StyleTwinTest do
  use ExUnit.Case, async: true

  alias Browser.{LayoutWorker, Page, Session, StyleGate}

  # A layout that a script waits for, and a prewarm of the same script and sheets that styles while
  # it starts: the prewarm is its twin (`Browser.StyleGate`). These tests start the jobs as the
  # session does (`Browser.Session.start_layout_job/2`), with no window.

  @env %{type: "screen", width: 800, height: 600, dppx: 1.0, font_units: nil}

  @html """
  <style>p { margin: 4px } .wide { width: 300px }</style>
  <div id="a"><p>one</p><p class="x">two</p></div>
  <div id="b"><p>three</p></div>
  """

  defp measure(:content_height, style), do: round(style.size)
  defp measure(text, style), do: String.length(text) * div(round(style.size), 2)

  defp style(css), do: {:element, "style", [], [{:text, css}]}

  defp set_attr(nodes, id, name, value) when is_list(nodes),
    do: Enum.map(nodes, &set_attr(&1, id, name, value))

  defp set_attr({:element, tag, attrs, kids}, id, name, value) do
    attrs =
      if {"id", id} in attrs,
        do: List.keystore(attrs, name, 0, {name, value}),
        else: attrs

    {:element, tag, attrs, set_attr(kids, id, name, value)}
  end

  defp set_attr(other, _, _, _), do: other

  defp drop_id({:element, tag, attrs, kids}, id) do
    kids = for k <- kids, not has_id?(k, id), do: drop_id(k, id)
    {:element, tag, attrs, kids}
  end

  defp drop_id(other, _id), do: other

  defp has_id?({:element, _, attrs, _}, id), do: {"id", id} in attrs
  defp has_id?(_other, _id), do: false

  defp set_text(nodes, old, new) when is_list(nodes), do: Enum.map(nodes, &set_text(&1, old, new))
  defp set_text({:text, old}, old, new), do: {:text, new}
  defp set_text({:element, t, a, kids}, old, new), do: {:element, t, a, set_text(kids, old, new)}
  defp set_text(other, _old, _new), do: other

  # The page as the session has it, the tree of the prewarm (a script added a sheet: the session
  # has no memo for it) and the tree of the request (the script then changed an element)
  defp trees(html \\ @html) do
    page = Page.build(html, "about:x", @env)
    prewarm = page.raw ++ [style(".x { font-size: 30px } #b { padding-left: 7px }")]
    forced = set_attr(prewarm, "b", "class", "wide")
    {page, prewarm, forced}
  end

  defp job(raw, refs, ref, seq, extra \\ %{}) do
    Map.merge(
      %{
        seq: seq,
        js: script(),
        ref: ref,
        raw: raw,
        refs: refs,
        deadline: System.monotonic_time(:millisecond) + 5_000,
        env: @env,
        width: 800,
        view_h: 600,
        measure: &measure/2,
        images: %{},
        worker: Process.get(:worker) || put_worker(),
        tid: :tab,
        session: self(),
        wx_env: nil,
        race: if(ref != nil, do: :atomics.new(1, [])),
        cold: nil
      },
      extra
    )
  end

  defp put_worker do
    worker = LayoutWorker.start(&measure/2)
    Process.put(:worker, worker)
    worker
  end

  # the boxes of a layout of `raw` with no twin and no memo: what a request must answer
  defp cold_rects(page, raw) do
    {base, refs} = Page.layout_base(%{page | memo: nil}, raw)
    Process.put(:style_gate, StyleGate.new())
    ref = make_ref()
    Session.start_layout_job(base, job(raw, refs, ref, 100))
    assert_receive {:script, {:layout_now_done, ^ref, rects, size}}, 5_000
    Process.delete(:style_gate)
    {rects, size}
  end

  # a stand-in for a process that is still busy
  defp busy, do: spawn(fn -> Process.sleep(:infinity) end)

  # A stand-in for the process of the scripts: it gives the test what it gets, so that the
  # test can tell an answer to the scripts from a message to the session (also the test)
  defp script do
    with nil <- Process.get(:script) do
      test = self()
      pid = spawn_link(fn -> forward(test) end)
      Process.put(:script, pid)
      pid
    end
  end

  defp forward(test) do
    receive do
      msg -> send(test, {:script, msg})
    end

    forward(test)
  end

  test "a request goes to the prewarm of the same script and sheets as its twin, not to one with other sheets" do
    {page, prewarm, forced} = trees()
    test = self()
    {_base, refs_p} = Page.layout_base(page, prewarm)

    # (a stand-in for the prewarm that styles: it gives the test what it gets)
    stand_in = spawn(fn -> receive do: (m -> send(test, {:prewarm_got, m})) end)

    gate = StyleGate.running(StyleGate.new(), 1, make_ref(), {{script(), refs_p}, stand_in})
    Process.put(:style_gate, gate)

    {base, refs} = Page.layout_base(page, forced)
    assert refs == refs_p
    assert base.memo == nil
    ref = make_ref()
    cold = Session.start_layout_job(base, job(forced, refs, ref, 2))

    assert_receive {:prewarm_got, {:style_twin, twin}}
    assert %{cold: ^cold, ref: ^ref, raw: ^forced, refs: ^refs} = twin
    # (the base goes without its style state: the twin puts that of the prewarm in it)
    assert %{rules: nil, memo: nil, sheet_cache: sheets} = twin.base
    assert sheets == %{}

    # (the request still styles and answers: here the twin does nothing)
    assert_receive {:script, {:layout_now_done, ^ref, _rects, _size}}, 5_000

    # A sheet that changed after the prewarm started: the request has other sheets, and goes
    # to no twin
    changed = forced ++ [style("p { color: teal }")]
    {base, refs} = Page.layout_base(page, changed)
    stand_in = spawn(fn -> receive do: (m -> send(test, {:prewarm_got, m})) end)
    gate = StyleGate.running(StyleGate.new(), 1, make_ref(), {{script(), refs_p}, stand_in})
    Process.put(:style_gate, gate)
    ref = make_ref()
    Session.start_layout_job(base, job(changed, refs, ref, 2))
    assert_receive {:script, {:layout_now_done, ^ref, _rects, _size}}, 5_000
    refute_received {:prewarm_got, _}

    # (and a request of another script neither)
    {base, refs} = Page.layout_base(page, forced)
    ref = make_ref()
    Session.start_layout_job(base, job(forced, refs, ref, 3, %{js: busy()}))
    refute_receive {:prewarm_got, _}, 100
  end

  test "the twin starts from the style state of the prewarm and answers as the request would" do
    {page, prewarm, forced} = trees()
    expected = cold_rects(page, forced)

    # the prewarm, styled from the page of the session
    {base_p, refs_p} = Page.layout_base(page, prewarm)
    styled = Page.from_raw(base_p, prewarm, @env, refs_p)

    # (the elements that did not change come from the memo of the prewarm; the tree of the
    # request may differ from that of the prewarm in any way)
    removed = Enum.map(forced, &drop_id(&1, "a"))
    text = set_text(forced, "three", "3")
    assert removed != forced and text != forced

    for raw <- [forced, removed, text, prewarm] do
      {base, refs} = Page.layout_base(page, raw)
      twin = job(raw, refs, nil, 7, %{base: Page.without_style(base)})
      {twin_base, twin_refs} = Session.twin_base(styled, twin)
      assert twin_refs == refs
      assert twin_base.memo == styled.memo
      fresh = Page.from_raw(base, raw, @env, refs)
      assert base.memo == nil
      assert Page.from_raw(twin_base, raw, @env, refs).pruned == fresh.pruned
      assert Page.from_raw(twin_base, raw, @env, refs).nodes == fresh.nodes
    end

    {base, refs} = Page.layout_base(page, forced)

    # The twin ends its style first: it sends its style state (without the rules: the session
    # has them from the prewarm), stops the request and answers
    cold = busy()
    watched = Process.monitor(cold)
    ref = make_ref()
    twin = job(forced, refs, ref, 7, %{cold: cold, base: Page.without_style(base)})
    spawn(fn -> Session.twin_layout(styled, twin) end)

    assert_receive {:style_state, 7, state}, 5_000
    refute Map.has_key?(state, :rules)
    assert state.sheet_refs == refs
    assert_receive {:DOWN, ^watched, _, _, :killed}
    assert_receive {:script, {:layout_now_done, ^ref, rects, size}}, 5_000
    assert {rects, size} == expected
  end

  test "of a request and its twin, only the one that ends its style first goes on" do
    race = :atomics.new(1, [])
    assert Session.won_style?(race, :run)
    refute Session.won_style?(race, :twin)
    assert Session.won_style?(nil, :run)

    {page, prewarm, forced} = trees()
    {base_p, refs_p} = Page.layout_base(page, prewarm)
    styled = Page.from_raw(base_p, prewarm, @env, refs_p)
    {base, refs} = Page.layout_base(page, forced)

    # (the request ended its style first: its twin does not start)
    ref = make_ref()
    cold = busy()
    twin = job(forced, refs, ref, 8, %{race: race, cold: cold, base: Page.without_style(base)})
    refute Session.twin_wanted?(twin)
    spawn(fn -> Session.twin_layout(styled, twin) end)
    refute_receive {:style_state, 8, _}, 200
    refute_received {:script, {:layout_now_done, ^ref, _, _}}
    assert Process.alive?(cold)

    # (nor when the script no longer waits)
    past = System.monotonic_time(:millisecond) - 1
    twin = %{twin | race: :atomics.new(1, []), deadline: past}
    refute Session.twin_wanted?(twin)

    # (the twin ended its style first: the request stops after its own style, with no style
    # state and no answer)
    race = :atomics.new(1, [])
    assert Session.won_style?(race, :twin)
    Process.put(:style_gate, StyleGate.new())
    ref = make_ref()
    pid = Session.start_layout_job(base, job(forced, refs, ref, 9, %{race: race}))
    watched = Process.monitor(pid)
    assert_receive {:DOWN, ^watched, _, _, :normal}, 5_000
    refute_received {:style_state, 9, _}
    refute_received {:script, {:layout_now_done, ^ref, _, _}}
  end

  test "a request whose prewarm is gone answers alone" do
    {page, prewarm, forced} = trees()
    expected = cold_rects(page, forced)
    {_base, refs_p} = Page.layout_base(page, prewarm)

    gone = spawn(fn -> :ok end)
    watched = Process.monitor(gone)
    assert_receive {:DOWN, ^watched, _, _, _}

    gate = StyleGate.running(StyleGate.new(), 1, make_ref(), {{script(), refs_p}, gone})
    Process.put(:style_gate, gate)
    {base, refs} = Page.layout_base(page, forced)
    ref = make_ref()
    Session.start_layout_job(base, job(forced, refs, ref, 2))
    assert_receive {:script, {:layout_now_done, ^ref, rects, size}}, 5_000
    assert {rects, size} == expected
  end

  test "a prewarm takes the newest twin that came to it" do
    send(self(), {:style_twin, :old})
    send(self(), {:style_twin, :new})
    assert Session.take_twin() == :new
    assert Session.take_twin() == nil
  end

  # The whole path: a prewarm styles, two requests of its script start while it runs. Whichever
  # of a request and its twin wins, each request gets one answer, the one of a cold layout.
  test "each request gets one answer, the same as with no twin" do
    {page, prewarm, forced} = trees()
    forced2 = set_attr(forced, "a", "hidden", "")
    expected = cold_rects(page, forced)
    expected2 = cold_rects(page, forced2)

    Process.put(:style_gate, StyleGate.new())
    {base_p, refs_p} = Page.layout_base(page, prewarm)
    Session.start_layout_job(base_p, job(prewarm, refs_p, nil, 1))

    {base, refs} = Page.layout_base(page, forced)
    ref = make_ref()
    Session.start_layout_job(base, job(forced, refs, ref, 2))
    {base2, refs2} = Page.layout_base(page, forced2)
    ref2 = make_ref()
    Session.start_layout_job(base2, job(forced2, refs2, ref2, 3))

    assert_receive {:script, {:layout_now_done, ^ref, rects, size}}, 5_000
    assert {rects, size} == expected
    assert_receive {:script, {:layout_now_done, ^ref2, rects, size}}, 5_000
    assert {rects, size} == expected2
    refute_receive {:script, {:layout_now_done, _, _, _}}, 300
  end

  # The request adds an element with a style attribute in viewport units, and no sheet. The twin
  # starts from the state of the prewarm, whose tree has no viewport units. The state that it
  # sends must tell that the tree of the request has them, as the state of the cold run does:
  # else, after a resize, the next layout takes the old size from the memo.
  test "the style state of a twin tells the viewport units of the tree of the request" do
    {page, prewarm, _forced} = trees()
    vw = {:element, "div", [{"id", "v"}, {"style", "width: 50vw"}], [{:text, "v"}]}
    forced = prewarm ++ [vw]
    expected = cold_rects(page, forced)

    {base_p, refs_p} = Page.layout_base(page, prewarm)
    styled = Page.from_raw(base_p, prewarm, @env, refs_p)
    refute styled.viewport_units
    # (the session gets the state of the prewarm first: the same process sends both)
    session = Page.adopt_style_state(page, Page.style_state(styled, base_p))

    {base, refs} = Page.layout_base(page, forced)
    # (the cold run finds them: it parses the new sheet, and looks at the tree again)
    assert Page.from_raw(base, forced, @env, refs).viewport_units
    ref = make_ref()
    twin = job(forced, refs, ref, 7, %{cold: busy(), base: Page.without_style(base)})
    spawn(fn -> Session.twin_layout(styled, twin) end)
    assert_receive {:style_state, 7, state}, 5_000
    assert_receive {:script, {:layout_now_done, ^ref, rects, size}}, 5_000
    assert {rects, size} == expected
    assert state.viewport_units

    session = Page.adopt_style_state(session, state)
    narrow = %{@env | width: 400}
    {base, refs} = Page.layout_base(session, forced)

    assert Page.from_raw(base, forced, narrow, refs).pruned ==
             Page.from_raw(%{page | memo: nil}, forced, narrow).pruned
  end

  # When the layout worker is busy, a run lays out in its own process. Then the prewarm lays
  # out its own tree and the tree of its twin in the same process: the second layout must not
  # use what the first one left in that process.
  test "a twin after a layout of the prewarm in the same process answers as a cold run" do
    {page, prewarm, forced} = trees()

    forced =
      forced |> set_text("one", "a much longer text in one") |> set_attr("a", "class", "wide")

    expected = cold_rects(page, forced)

    {base_p, refs_p} = Page.layout_base(page, prewarm)
    styled = Page.from_raw(base_p, prewarm, @env, refs_p)
    flag = :atomics.new(1, [])
    :atomics.put(flag, 1, 1)
    worker = %LayoutWorker{pid: busy(), busy: flag}

    {base, refs} = Page.layout_base(page, forced)
    ref = make_ref()
    extra = %{cold: busy(), base: Page.without_style(base), worker: worker}
    twin = job(forced, refs, ref, 7, extra)
    opts = [scrollers: true, boxes: true, metrics: true, images: %{}, svg_defs: styled.svg_defs]

    spawn(fn ->
      LayoutWorker.layout(worker, :tab, styled.nodes, 800, &measure/2, 600, opts)
      Session.twin_layout(styled, twin)
    end)

    assert_receive {:script, {:layout_now_done, ^ref, rects, size}}, 5_000
    assert {rects, size} == expected
  end

  # A twin that comes to the prewarm after the script stopped waiting: the prewarm does not
  # style it, does not stop its request, and ends.
  test "a twin that comes too late does nothing, and the prewarm ends" do
    {page, prewarm, forced} = trees()
    Process.put(:style_gate, StyleGate.new())
    {base_p, refs_p} = Page.layout_base(page, prewarm)
    pre = Session.start_layout_job(base_p, job(prewarm, refs_p, nil, 1))
    watched = Process.monitor(pre)

    {base, refs} = Page.layout_base(page, forced)
    cold = busy()
    ref = make_ref()
    past = System.monotonic_time(:millisecond) - 1
    extra = %{cold: cold, base: Page.without_style(base), deadline: past}
    send(pre, {:style_twin, job(forced, refs, ref, 2, extra)})

    assert_receive {:DOWN, ^watched, _, _, :normal}, 5_000
    assert_received {:style_state, 1, _}
    refute_received {:style_state, 2, _}
    refute_received {:script, {:layout_now_done, ^ref, _, _}}
    assert Process.alive?(cold)
    Process.exit(cold, :kill)
  end

  # The session side, as `Browser.Session` does it: the test adopts the style states and tells
  # the gate (`handle_info/2`). Gives the page of the session and the answers that came.
  defp pump(page, answers, wait) do
    receive do
      {:style_state, _seq, _style} = msg ->
        {:noreply, state} = Session.handle_info(msg, %{page: page})
        pump(state.page, answers, wait)

      {:style_gate_down, _mon, :process, _pid, _reason} = msg ->
        {:noreply, state} = Session.handle_info(msg, %{page: page})
        pump(state.page, answers, wait)

      {:script, {:layout_now_done, ref, rects, size}} ->
        pump(page, [{ref, {rects, size}} | answers], wait)
    after
      wait -> {page, answers}
    end
  end

  # The whole path many times, with the requests at random times while the prewarm runs, and
  # the session that adopts each style state as it comes: each request gets one answer, that of
  # a cold layout of its tree. At the end all the processes of the runs stopped, and the gate has
  # no run and no twin.
  @tag :slow
  test "requests at random times during a prewarm each get one right answer" do
    rows = String.duplicate(~s(<div class="r"><p>row</p><span>s</span></div>), 1500)
    # (the rows come first: the requests change only what comes after them, so the twin can
    # take the rows from the memo of the prewarm, and can end its style first)
    {page, prewarm, forced} = trees(rows <> @html)

    raws = [
      forced,
      set_attr(forced, "a", "hidden", ""),
      forced |> Enum.map(&drop_id(&1, "a")) |> set_text("three", "3")
    ]

    expected = Enum.map(raws, &cold_rects(page, &1))

    for _round <- 1..6 do
      Process.put(:style_gate, StyleGate.new())
      {base_p, refs_p} = Page.layout_base(page, prewarm)
      pre = Session.start_layout_job(base_p, job(prewarm, refs_p, nil, 1))
      watched = [Process.monitor(pre)]

      {session, answers, watched, refs} =
        raws
        |> Enum.with_index(2)
        |> Enum.reduce({page, [], watched, []}, fn {raw, seq},
                                                   {session, answers, watched, refs} ->
          {session, answers} = pump(session, answers, :rand.uniform(80) - 1)
          {base, sheets} = Page.layout_base(session, raw)
          ref = make_ref()
          pid = Session.start_layout_job(base, job(raw, sheets, ref, seq))
          {session, answers, [Process.monitor(pid) | watched], refs ++ [ref]}
        end)

      answers =
        Enum.reduce(watched, answers, fn mon, answers ->
          {_session, answers} = pump(session, answers, 0)
          assert_receive {:DOWN, ^mon, _, _, _}, 10_000
          answers
        end)

      {_session, answers} = pump(session, answers, 300)
      assert Enum.sort(answers) == Enum.sort(Enum.zip(refs, expected))
      assert %{runs: runs, twins: twins} = Process.get(:style_gate)
      assert {runs, twins} == {%{}, %{}}
    end
  end
end
