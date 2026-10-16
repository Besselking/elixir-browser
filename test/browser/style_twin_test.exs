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

  defp has_id?({:element, _, attrs, _}, id), do: {"id", id} in attrs
  defp has_id?(_other, _id), do: false

  defp drop_id(other, _id), do: other

  defp set_text(nodes, old, new) when is_list(nodes), do: Enum.map(nodes, &set_text(&1, old, new))
  defp set_text({:text, old}, old, new), do: {:text, new}
  defp set_text({:element, t, a, kids}, old, new), do: {:element, t, a, set_text(kids, old, new)}
  defp set_text(other, _old, _new), do: other

  # The page as the session has it, the tree of the prewarm (a script added a sheet: the session
  # has no memo for it) and the tree of the request (the script then changed an element)
  defp trees do
    page = Page.build(@html, "about:x", @env)
    prewarm = page.raw ++ [style(".x { font-size: 30px } #b { padding-left: 7px }")]
    forced = set_attr(prewarm, "b", "class", "wide")
    {page, prewarm, forced}
  end

  defp job(raw, refs, ref, seq, extra \\ %{}) do
    Map.merge(
      %{
        seq: seq,
        js: self(),
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
    assert_receive {:layout_now_done, ^ref, rects, size}, 5_000
    Process.delete(:style_gate)
    {rects, size}
  end

  # a stand-in for a process that is still busy
  defp busy, do: spawn(fn -> Process.sleep(:infinity) end)

  test "a request goes to the prewarm of the same script and sheets as its twin, not to one with other sheets" do
    {page, prewarm, forced} = trees()
    test = self()
    {_base, refs_p} = Page.layout_base(page, prewarm)

    # (a stand-in for the prewarm that styles: it gives the test what it gets)
    stand_in = spawn(fn -> receive do: (m -> send(test, {:prewarm_got, m})) end)

    gate = StyleGate.running(StyleGate.new(), 1, make_ref(), {{self(), refs_p}, stand_in})
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
    assert_receive {:layout_now_done, ^ref, _rects, _size}, 5_000

    # A sheet that changed after the prewarm started: the request has other sheets, and goes
    # to no twin
    changed = forced ++ [style("p { color: teal }")]
    {base, refs} = Page.layout_base(page, changed)
    stand_in = spawn(fn -> receive do: (m -> send(test, {:prewarm_got, m})) end)
    gate = StyleGate.running(StyleGate.new(), 1, make_ref(), {{self(), refs_p}, stand_in})
    Process.put(:style_gate, gate)
    ref = make_ref()
    Session.start_layout_job(base, job(changed, refs, ref, 2))
    assert_receive {:layout_now_done, ^ref, _rects, _size}, 5_000
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
    assert_receive {:layout_now_done, ^ref, rects, size}, 5_000
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
    refute_received {:layout_now_done, ^ref, _, _}
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
    refute_received {:layout_now_done, ^ref, _, _}
  end

  test "a request whose prewarm is gone answers alone" do
    {page, prewarm, forced} = trees()
    expected = cold_rects(page, forced)
    {_base, refs_p} = Page.layout_base(page, prewarm)

    gone = spawn(fn -> :ok end)
    watched = Process.monitor(gone)
    assert_receive {:DOWN, ^watched, _, _, _}

    gate = StyleGate.running(StyleGate.new(), 1, make_ref(), {{self(), refs_p}, gone})
    Process.put(:style_gate, gate)
    {base, refs} = Page.layout_base(page, forced)
    ref = make_ref()
    Session.start_layout_job(base, job(forced, refs, ref, 2))
    assert_receive {:layout_now_done, ^ref, rects, size}, 5_000
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

    assert_receive {:layout_now_done, ^ref, rects, size}, 5_000
    assert {rects, size} == expected
    assert_receive {:layout_now_done, ^ref2, rects, size}, 5_000
    assert {rects, size} == expected2
    refute_receive {:layout_now_done, _, _, _}, 300
  end
end
