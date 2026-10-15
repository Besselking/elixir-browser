defmodule Browser.StyleGateTest do
  use ExUnit.Case, async: true

  alias Browser.StyleGate

  # a request of the script `js`: `ref` nil is a prewarm
  defp req(js, ref, tag), do: %{js: js, ref: ref, tag: tag}

  # starts the requests as the session does: one process each, monitored with a tag. (The
  # process waits for `:go` until the monitor is in place: a process that stops before that
  # gives the reason `:noproc`.)
  defp start(gate, reqs, fun) do
    Enum.reduce(reqs, gate, fn r, gate ->
      pid =
        spawn(fn ->
          receive do: (:go -> :ok)
          fun.(r)
        end)

      mon = :erlang.monitor(:process, pid, tag: :style_gate_down)
      send(pid, :go)
      StyleGate.running(gate, r.seq, mon)
    end)
  end

  test "a request starts at once when no run is in flight" do
    {[r], _gate} = StyleGate.request(StyleGate.new(), req(:js, nil, :a))
    assert r.tag == :a
    assert r.seq == 1
  end

  test "a prewarm waits for the run in flight and starts when that run sends its style state" do
    {[a], gate} = StyleGate.request(StyleGate.new(), req(:js, nil, :a))
    gate = StyleGate.running(gate, a.seq, :mon_a)
    assert {[], gate} = StyleGate.request(gate, req(:js, nil, :b))

    assert {true, :mon_a, [b], gate} = StyleGate.style_done(gate, a.seq)
    assert b.tag == :b
    gate = StyleGate.running(gate, b.seq, :mon_b)
    assert {true, :mon_b, [], _gate} = StyleGate.style_done(gate, b.seq)
  end

  test "a request that a script waits for starts at once and replaces the prewarm of its script" do
    {[a], gate} = StyleGate.request(StyleGate.new(), req(:js, nil, :a))
    gate = StyleGate.running(gate, a.seq, :mon_a)
    {[], gate} = StyleGate.request(gate, req(:js, nil, :b))
    {[], gate} = StyleGate.request(gate, req(:other, nil, :c))

    assert {[f], gate} = StyleGate.request(gate, req(:js, make_ref(), :forced))
    assert f.tag == :forced
    gate = StyleGate.running(gate, f.seq, :mon_f)

    # (the prewarm :b is gone; the prewarm of the other script waits for both runs)
    assert {true, :mon_f, [], gate} = StyleGate.style_done(gate, f.seq)
    # (the run that started first ends last: its older state is not adopted)
    assert {false, :mon_a, [c], _gate} = StyleGate.style_done(gate, a.seq)
    assert c.tag == :c
  end

  # A run that a script waits for sends its style state after its answer. The script can ask
  # again before that state arrives: the new request then waits for it, so that it does not
  # style again from an older state.
  test "a script that asks again waits for the style state of the run that answered it" do
    now = 1_000_000
    wait = Browser.JS.DOM.layout_wait()
    forced = fn js, tag, at -> req(js, make_ref(), tag) |> Map.put(:deadline, at + wait) end

    {[a], gate} = StyleGate.request(StyleGate.new(), forced.(:js, :a, now))
    gate = StyleGate.running(gate, a.seq, :mon_a)

    # (the answer came at once: the script asks again while the state of :a is on its way)
    assert {[], gate} = StyleGate.request(gate, forced.(:js, :b, now + 50))
    # (another script does not wait, and a prewarm still waits for the run in flight)
    assert {[c], gate} = StyleGate.request(gate, forced.(:other, :c, now + 60))
    gate = StyleGate.running(gate, c.seq, :mon_c)
    assert {[], gate} = StyleGate.request(gate, req(:third, nil, :d))

    assert {true, :mon_a, [b], gate} = StyleGate.style_done(gate, a.seq)
    assert b.tag == :b
    gate = StyleGate.running(gate, b.seq, :mon_b)

    # (a run that stops before it sends its state also lets the request start)
    assert {[], gate} = StyleGate.request(gate, forced.(:js, :e, now + 100))
    assert {[e], gate} = StyleGate.down(gate, :mon_b)
    assert e.tag == :e
    gate = StyleGate.running(gate, e.seq, :mon_e)

    # (the prewarm :d starts when no run is in flight)
    assert {true, :mon_c, [], gate} = StyleGate.style_done(gate, c.seq)
    assert {true, :mon_e, [d], _gate} = StyleGate.style_done(gate, e.seq)
    assert d.tag == :d
  end

  test "a script that asks again after the deadline of its run does not wait for it" do
    wait = Browser.JS.DOM.layout_wait()
    forced = fn tag, at -> req(:js, make_ref(), tag) |> Map.put(:deadline, at + wait) end

    {[a], gate} = StyleGate.request(StyleGate.new(), forced.(:a, 0))
    gate = StyleGate.running(gate, a.seq, :mon_a)
    assert {[b], _gate} = StyleGate.request(gate, forced.(:b, wait))
    assert b.tag == :b
  end

  test "the gate opens when a run stops before it sends its style state" do
    test = self()
    {[a], gate} = StyleGate.request(StyleGate.new(), req(:js, nil, :a))
    gate = start(gate, [a], fn _ -> exit(:style_failed) end)
    {[], gate} = StyleGate.request(gate, req(:js, nil, :b))

    assert_receive {:style_gate_down, mon, :process, _pid, :style_failed}
    {next, gate} = StyleGate.down(gate, mon)
    assert [%{tag: :b} = b] = next

    gate = start(gate, next, fn r -> send(test, {:started, r.tag}) end)
    assert_receive {:started, :b}
    assert {true, _mon, [], _gate} = StyleGate.style_done(gate, b.seq)
  end

  test "the end of a run after it sent its style state does not start a request" do
    {[a], gate} = StyleGate.request(StyleGate.new(), req(:js, nil, :a))
    gate = StyleGate.running(gate, a.seq, :mon_a)
    {true, :mon_a, [], gate} = StyleGate.style_done(gate, a.seq)
    assert {[], ^gate} = StyleGate.down(gate, :mon_a)
  end

  # The session keeps the gate in its process dictionary (here: that of the test). A style state
  # that comes late from an older run must not replace the state of a newer run. (No request
  # waits, so no layout starts.)
  test "the session does not adopt the style state of an older run over a newer one" do
    page = %Browser.Page{sheet_cache: %{}}
    state = %{page: page}

    {[a], gate} = StyleGate.request(StyleGate.new(), req(:js, nil, :a))
    {[b], gate} = StyleGate.request(gate, req(:js, make_ref(), :b))
    gate = gate |> StyleGate.running(a.seq, make_ref()) |> StyleGate.running(b.seq, make_ref())
    Process.put(:style_gate, gate)

    style = fn rules ->
      %{
        rules: rules,
        queries: [],
        sheet_refs: [],
        sheet_cache: %{},
        viewport_units: false,
        memo: nil
      }
    end

    assert {:noreply, state} =
             Browser.Session.handle_info({:style_state, b.seq, style.([:new])}, state)

    assert state.page.rules == [:new]

    assert {:noreply, state} =
             Browser.Session.handle_info({:style_state, a.seq, style.([:old])}, state)

    assert state.page.rules == [:new]
    assert Process.get(:style_gate).runs == %{}
  end

  # A prewarm waits while another run styles. When it can start, the scripts that asked for it
  # may be gone (another page, another tab): then it does not start, and the next one does.
  test "the session drops a prewarm of scripts that no longer run" do
    {[a], gate} = StyleGate.request(StyleGate.new(), req(:js, make_ref(), :a))
    gate = StyleGate.running(gate, a.seq, make_ref())
    {[], gate} = StyleGate.request(gate, req(:old_js, nil, :b))
    {[], gate} = StyleGate.request(gate, req(:old_js2, nil, :c))
    Process.put(:style_gate, gate)

    # (`:js` is not a page that can be laid out: a layout that started here would crash)
    state = %{page: %Browser.Page{sheet_cache: %{}}, js: :new_js}

    style = %{
      rules: [],
      queries: [],
      sheet_refs: [],
      sheet_cache: %{},
      viewport_units: false,
      memo: nil
    }

    assert {:noreply, _state} = Browser.Session.handle_info({:style_state, a.seq, style}, state)
    assert %{runs: runs, queue: []} = Process.get(:style_gate)
    assert runs == %{}
  end
end
