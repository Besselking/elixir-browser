defmodule Browser.Session do
  @moduledoc """
  Owns the wx environment, history and current document. All wx calls happen
  in this process; page loads run in tasks and report back by message.

  Besides navigation it handles form interaction: one control can have keyboard focus
  (shown with a ring, and a blinking caret in text fields); typing edits its value in
  the page's form state (`Browser.Forms`), and the page is re-rendered and laid out
  again without re-running the style cascade.
  """
  use GenServer
  import Browser.UI, only: [wx: 1, wxMouse: 1, wxCommand: 1, wxSize: 1]

  alias Browser.{Fetch, Forms, History, Images, Interact, Layout, Page, Selection, TextEdit, UI}

  @blink_ms 530
  # pixels per line of wheel scrolling (3 lines per 120-unit notch = the old 120px per notch)
  # pixels per line of a notch of the wheel
  @wheel_line 24

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def navigate(url), do: GenServer.cast(__MODULE__, {:navigate, url})

  @impl true
  def init(_) do
    ui = UI.build()

    state = %{
      ui: ui,
      measure: UI.measurer(ui),
      history: History.new(),
      page: nil,
      nodes: [],
      items: [],
      # links indexed by band (UI.links/1), so hover needn't scan every item
      links: %{},
      controls: %{},
      # decoded pictures by url: {:ok, width, height} or :failed
      images: %{},
      layout_timer: nil,
      height: 0,
      scroll: 0,
      # horizontal scroll, and the width of what the page lays out (wider than the window
      # when something overflows)
      scroll_x: 0,
      content_w: 0,
      wheel_rem_x: 0.0,
      # sub-pixel remainder of precise wheel input, carried to the next event
      wheel_rem: 0.0,
      width: UI.client_width(ui),
      nonce: 0,
      hover: {nil, :arrow},
      url: nil,
      # form interaction: the focused control, its caret (graphemes), blink state, and
      # the control whose option menu is open
      focus: nil,
      caret: 0,
      caret_on: true,
      blink: nil,
      menu: nil,
      # selected page text: the range, its anchor while dragging, the selectable text items
      # (computed when needed) and the highlight items drawn over them
      sel: nil,
      sel_anchor: nil,
      drag: false,
      sel_texts: nil,
      sel_items: [],
      # the last click, for double and triple clicks: {time, x, y, count}
      click: nil,
      # text selected in the focused field: the other end of the selection (the caret is
      # one end), and whether the mouse is dragging it out
      fanchor: nil,
      fdrag: false
    }

    start = System.get_env("BROWSER_URL") || Browser.home()
    {:ok, state, {:continue, {:go, start}}}
  end

  @impl true
  def handle_continue({:go, url}, state), do: {:noreply, load(state, Fetch.normalize(url), :push)}

  @impl true
  def handle_cast({:navigate, url}, state),
    do: {:noreply, load(state, Fetch.normalize(url), :push)}

  # -- loading -------------------------------------------------------------

  defp load(state, url, mode, fetch_opts \\ []) do
    me = self()
    nonce = state.nonce + 1
    UI.set_status(state.ui, "Loading #{url}…")
    env = env(state)
    Task.start(fn -> send(me, {:loaded, nonce, url, mode, Page.load(url, env, fetch_opts)}) end)
    %{state | nonce: nonce}
  end

  @impl true
  def handle_info({:loaded, nonce, _, _, _}, %{nonce: n} = state) when nonce != n,
    do: {:noreply, state}

  def handle_info({:loaded, _, url, mode, result}, state) do
    page =
      case result do
        {:ok, page} ->
          page

        {:error, msg} ->
          Page.build("<h1>Error</h1><p>#{escape(msg)}</p><p>#{escape(url)}</p>", url, env(state))
      end

    history =
      case mode do
        :push -> History.visit(state.history, page.url)
        :history -> state.history
      end

    UI.set_url_text(state.ui, page.url)
    UI.set_title(state.ui, (page.title || page.url) <> " — Elixir Browser")
    UI.set_status(state.ui, "Done")

    state =
      state
      |> stop_blink()
      |> Map.merge(%{
        history: history,
        page: page,
        nodes: page.nodes,
        url: page.url,
        scroll: 0,
        focus: nil,
        caret: 0,
        controls: %{},
        menu: nil
      })

    {:noreply, state |> relayout() |> sync_buttons() |> start_images()}
  end

  # -- images arriving -------------------------------------------------------

  def handle_info({:image, nonce, url, result}, %{nonce: nonce} = state) do
    info =
      case result do
        {:ok, scene, :svg} ->
          {w, h} = Browser.Svg.intrinsic(scene)
          {:svg, max(round(w), 1), max(round(h), 1), scene}

        {:ok, bytes, format} ->
          case UI.load_image(url, bytes, format) do
            {:ok, w, h} -> {:ok, w, h}
            _ -> :failed
          end

        _ ->
          :failed
      end

    {:noreply, state |> put_in([:images, url], info) |> schedule_image_layout()}
  end

  def handle_info({:image, _stale, _url, _result}, state), do: {:noreply, state}

  # a fetch that was killed on timeout never reports, so mark what is still missing
  def handle_info({:images_done, nonce, urls}, %{nonce: nonce} = state) do
    images = Enum.reduce(urls, state.images, &Map.put_new(&2, &1, :failed))
    {:noreply, schedule_image_layout(%{state | images: images})}
  end

  def handle_info({:images_done, _stale, _urls}, state), do: {:noreply, state}

  # several pictures usually arrive together: lay out once for the batch
  def handle_info({:image_layout, ref}, %{layout_timer: ref} = state),
    do: {:noreply, relayout(%{state | layout_timer: nil})}

  def handle_info({:image_layout, _stale}, state), do: {:noreply, state}

  # -- blinking caret --------------------------------------------------------

  def handle_info({:blink, ref}, %{blink: ref} = state) do
    state = %{state | caret_on: not state.caret_on}
    UI.update(state.ui, view_items(state), state.scroll, state.caret_on, :diff)
    {:noreply, schedule_blink(state, false)}
  end

  def handle_info({:blink, _stale}, state), do: {:noreply, state}

  # -- wx events -------------------------------------------------------------

  def handle_info(wx(event: {:wxClose, :close_window}), state) do
    # An orderly shutdown frees the toolkit's objects while its event loop is still
    # running, which crashes the wx driver (a "quit unexpectedly" dialog on macOS).
    # There is nothing to save, so leave straight away.
    System.halt(0)
    {:noreply, state}
  end

  def handle_info(
        wx(obj: obj, event: wxCommand(type: :command_text_enter, cmdString: str)),
        state
      )
      when obj == state.ui.url,
      do: {:noreply, load(state, Fetch.normalize(to_string(str)), :push)}

  def handle_info(wx(obj: obj, event: wxCommand(type: :command_button_clicked)), state) do
    ui = state.ui

    cond do
      obj == ui.back -> {:noreply, history_nav(state, &History.back/1)}
      obj == ui.forward -> {:noreply, history_nav(state, &History.forward/1)}
      obj == ui.reload -> {:noreply, (state.url && load(state, state.url, :history)) || state}
      true -> {:noreply, state}
    end
  end

  # Quit (Cmd+Q and the application menu's item)
  def handle_info(wx(id: 5006, event: wxCommand(type: :command_menu_selected)), _state),
    do: System.halt(0)

  # Edit > Cut, Copy and Select All (wxID_CUT, wxID_COPY, wxID_SELECTALL)
  def handle_info(wx(id: 5031, event: wxCommand(type: :command_menu_selected)), state),
    do: {:noreply, on_key(state, :cut)}

  def handle_info(wx(id: 5032, event: wxCommand(type: :command_menu_selected)), state),
    do: {:noreply, on_key(state, :copy)}

  def handle_info(wx(id: 5035, event: wxCommand(type: :command_menu_selected)), state),
    do: {:noreply, on_key(state, :select_all)}

  # a choice from the open <select> menu
  def handle_info(wx(id: id, event: wxCommand(type: :command_menu_selected)), state) do
    {:noreply, choose_option(state, id - UI.menu_base())}
  end

  def handle_info(wx(event: wxMouse(type: :left_down, x: wx_x, y: y, shiftDown: shift)), state) do
    x = wx_x + state.scroll_x
    UI.focus_page(state.ui)
    py = y + state.scroll
    {count, state} = register_click(state, x, y, :down)

    case UI.control_at(state.controls, x, py) do
      nil ->
        state = if state.focus, do: blur(state), else: state

        case UI.link_at(state.links, x, py) do
          nil -> {:noreply, page_click(state, x, py, count, shift)}
          href -> {:noreply, load(state, Fetch.resolve(state.url, href), :push)}
        end

      cid ->
        {:noreply, click_control(state, cid, x, py, count, shift)}
    end
  end

  def handle_info(wx(event: wxMouse(type: :left_dclick, x: wx_x, y: y)), state) do
    x = wx_x + state.scroll_x
    py = y + state.scroll
    {count, state} = register_click(state, x, y, :dclick)

    case UI.control_at(state.controls, x, py) do
      nil ->
        if UI.link_at(state.links, x, py) == nil,
          do: {:noreply, select_unit(state, x, py, count)},
          else: {:noreply, state}

      cid ->
        {:noreply, click_control(state, cid, x, py, count, false)}
    end
  end

  def handle_info(wx(event: wxMouse(type: :left_up)), state), do: {:noreply, end_drag(state)}

  # dragging out a selection in a text field
  def handle_info(
        wx(event: wxMouse(type: :motion, x: wx_x, y: y, leftDown: down)),
        %{fdrag: true} = state
      ) do
    x = wx_x + state.scroll_x

    if down,
      do: {:noreply, drag_field(state, x, y + state.scroll)},
      else: {:noreply, end_drag(state)}
  end

  # dragging out a selection; past the top or bottom edge the page scrolls along
  def handle_info(
        wx(event: wxMouse(type: :motion, x: wx_x, y: y, leftDown: down)),
        %{drag: true} = state
      ) do
    x = wx_x + state.scroll_x

    if down do
      view = UI.client_height(state.ui)

      state =
        cond do
          y < 0 -> scroll_by(state, -24)
          y > view -> scroll_by(state, 24)
          true -> state
        end

      {:noreply, extend_selection(state, x, y + state.scroll)}
    else
      {:noreply, end_drag(state)}
    end
  end

  def handle_info(wx(event: wxMouse(type: :motion, x: wx_x, y: y)), state) do
    x = wx_x + state.scroll_x
    py = y + state.scroll
    href = UI.link_at(state.links, x, py)
    {texts, state} = sel_texts(state)

    kind =
      case UI.control_at(state.controls, x, py) do
        nil ->
          cond do
            href -> :hand
            Selection.over_text?(texts, x, py) -> :text
            true -> :arrow
          end

        cid ->
          control_cursor(state, cid)
      end

    {old_href, old_kind} = state.hover
    if kind != old_kind, do: UI.set_cursor(state.ui, kind)

    if href != old_href,
      do: UI.set_status(state.ui, if(href, do: Fetch.resolve(state.url, href), else: ""))

    {:noreply, %{state | hover: {href, kind}}}
  end

  def handle_info({:wheel, rot, delta, lines}, state) do
    # a trackpad or momentum flick delivers dozens of events a second: fold every wheel event
    # already queued into this one so a burst costs one scroll and one repaint
    {rot, state} = drain_wheel(wheel_rotation(rot, delta, lines), state)
    px = state.wheel_rem - rot
    whole = trunc(px)
    {:noreply, scroll_by(%{state | wheel_rem: px - whole}, whole)}
  end

  def handle_info({:hwheel, rot, delta, lines}, state) do
    {rot, state} = drain_hwheel(wheel_rotation(rot, delta, lines), state)
    px = state.wheel_rem_x + rot
    whole = trunc(px)
    {:noreply, scroll_x_by(%{state | wheel_rem_x: px - whole}, whole)}
  end

  def handle_info(wx(event: wxSize(size: {w, _})), state) do
    cond do
      w == state.width ->
        {:noreply, state}

      state.page == nil ->
        {:noreply, %{state | width: w}}

      true ->
        state = %{state | width: w}
        page = Page.restyle(state.page, env(state))
        state = relayout(%{state | page: page, nodes: page.nodes})
        # a new viewport can switch on other background images
        {:noreply, start_images(state)}
    end
  end

  def handle_info(wx(event: event), state) when elem(event, 0) == :wxKey do
    key = event |> UI.key_event() |> Interact.key()
    {:noreply, on_key(state, key)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- keyboard --------------------------------------------------------------

  defp on_key(state, :ignore), do: state

  defp on_key(state, key) when key in [:copy, :select_all, :cut] do
    case editing_control(state) do
      nil -> if key == :cut, do: state, else: page_selection_key(state, key)
      control -> edit_key(state, control, key)
    end
  end

  defp on_key(%{focus: nil} = state, key) when key in [:tab, :shift_tab],
    do: focus_step(state, if(key == :tab, do: :forward, else: :backward))

  defp on_key(%{focus: nil} = state, key), do: page_key(state, key)

  defp on_key(state, key) do
    case control(state, state.focus) do
      nil -> page_key(%{state | focus: nil}, key)
      control -> control_key(state, control, key)
    end
  end

  defp control_key(state, _control, :escape), do: blur(state)
  defp control_key(state, _control, :tab), do: focus_step(state, :forward)
  defp control_key(state, _control, :shift_tab), do: focus_step(state, :backward)

  defp control_key(state, control, key) do
    cond do
      Forms.editable?(control) -> edit_key(state, control, key)
      control.type in ["checkbox", "radio"] -> toggle_key(state, control, key)
      control.tag == "select" -> select_key(state, control, key)
      button?(control) -> button_key(state, control, key)
      true -> page_key(state, key)
    end
  end

  defp editing_control(%{focus: nil}), do: nil

  defp editing_control(state) do
    case control(state, state.focus) do
      %{} = control -> if Forms.editable?(control), do: control
      nil -> nil
    end
  end

  defp edit_key(state, control, :copy) do
    cur = Forms.current(control, state.page.form_state)
    text = TextEdit.selected(cur.value, TextEdit.selection(state.caret, state.fanchor))
    if text != "", do: UI.set_clipboard_text(text)
    state
  end

  defp edit_key(state, control, key) do
    cur = Forms.current(control, state.page.form_state)
    multiline? = Forms.multiline?(control)
    opts = [multiline: multiline?, max: control.maxlength]

    cut_text =
      if key == :cut,
        do: TextEdit.selected(cur.value, TextEdit.selection(state.caret, state.fanchor))

    sel_key =
      case key do
        :paste -> {:char, UI.clipboard_text()}
        _ -> key
      end

    result = TextEdit.apply_sel({cur.value, state.caret}, state.fanchor, sel_key, opts)
    if cut_text not in [nil, ""] and result != :ignored, do: UI.set_clipboard_text(cut_text)

    case {result, key} do
      {{value, caret, anchor}, _} ->
        old_text = if(multiline?, do: nil, else: Forms.visible_text(control, cur))

        %{state | fanchor: anchor}
        |> edit(control.cid, value, caret)
        |> reset_blink()
        |> relayout_edit(control, old_text)

      # Enter in a single-line field submits its form
      {:ignored, :enter} ->
        submit(state, control.form, nil)

      {:ignored, k} when k in [:page_up, :page_down] ->
        page_key(state, k)

      _ ->
        state
    end
  end

  defp edit(state, cid, value, caret) do
    form_state = Forms.put(state.page.form_state, cid, value: value)
    set_form_state(state, form_state) |> Map.put(:caret, caret)
  end

  defp toggle_key(state, control, {:char, " "}), do: toggle(state, control.cid)
  defp toggle_key(state, _control, key), do: page_key(state, key)

  defp select_key(state, control, key) do
    case key do
      :up -> step_option(state, control, -1)
      :down -> step_option(state, control, 1)
      k when k in [:enter, {:char, " "}] -> open_select(state, control)
      _ -> page_key(state, key)
    end
  end

  defp button_key(state, control, key) when key in [:enter, {:char, " "}],
    do: activate(state, control)

  defp button_key(state, _control, key), do: page_key(state, key)

  # scrolling the page when nothing consumes the key
  defp page_key(state, key) do
    page = UI.client_height(state.ui) - 40

    case key do
      :up -> scroll_by(state, -40)
      :down -> scroll_by(state, 40)
      :left -> scroll_x_by(state, -40)
      :right -> scroll_x_by(state, 40)
      :page_up -> scroll_by(state, -page)
      :page_down -> scroll_by(state, page)
      {:char, " "} -> scroll_by(state, page)
      :home -> scroll_by(state, -state.scroll)
      :end -> scroll_by(state, state.height)
      :escape -> apply_selection(state, nil)
      _ -> state
    end
  end

  # -- selecting page text ---------------------------------------------------

  defp view_items(%{sel_items: []} = state), do: state.items
  defp view_items(state), do: state.items ++ state.sel_items

  defp sel_texts(%{sel_texts: nil} = state) do
    texts = Selection.texts(state.items)
    {texts, %{state | sel_texts: texts}}
  end

  defp sel_texts(state), do: {state.sel_texts, state}

  # A press on plain page area: a triple click selects the paragraph; with shift the
  # selection grows from where it started; otherwise a new selection begins.
  defp page_click(state, x, py, count, _shift) when count >= 3, do: select_unit(state, x, py, 3)

  defp page_click(%{sel_anchor: anchor} = state, x, py, _count, true) when anchor != nil do
    extend_selection(%{state | drag: true}, x, py)
  end

  defp page_click(state, x, py, _count, _shift), do: start_selection(state, x, py)

  # clicks at (about) the same place in quick succession count up
  defp register_click(state, x, y, kind) do
    now = System.monotonic_time(:millisecond)

    count =
      case state.click do
        {t, cx, cy, n} when now - t < 500 and abs(x - cx) < 5 and abs(y - cy) < 5 -> n + 1
        _ -> if kind == :dclick, do: 2, else: 1
      end

    {count, %{state | click: {now, x, y, count}}}
  end

  defp select_unit(state, x, py, count) do
    {texts, state} = sel_texts(state)

    with pos when pos != nil <- Selection.point_at(texts, x, py, state.measure),
         range when range != nil <-
           if(count >= 3,
             do: Selection.paragraph_at(texts, pos),
             else: Selection.word_at(texts, pos)
           ) do
      apply_selection(%{state | sel_anchor: elem(range, 0), drag: false}, range)
    else
      _ -> state
    end
  end

  defp start_selection(state, x, py) do
    {texts, state} = sel_texts(state)
    anchor = Selection.point_at(texts, x, py, state.measure)
    apply_selection(%{state | sel_anchor: anchor, drag: anchor != nil}, nil)
  end

  defp extend_selection(%{sel_anchor: nil} = state, _x, _py), do: state

  defp extend_selection(state, x, py) do
    {texts, state} = sel_texts(state)
    head = Selection.point_at(texts, x, py, state.measure)
    apply_selection(state, Selection.range(state.sel_anchor, head))
  end

  defp end_drag(state), do: %{state | drag: false, fdrag: false}

  defp page_selection_key(state, :select_all) do
    {texts, state} = sel_texts(state)
    apply_selection(state, Selection.all(texts))
  end

  defp page_selection_key(state, :copy) do
    {texts, state} = sel_texts(state)

    case Selection.text(texts, state.sel) do
      "" ->
        state

      text ->
        UI.set_clipboard_text(text)
        state
    end
  end

  # shows `range` (nil: nothing) as the selection, repainting only if it changed
  defp apply_selection(state, range) do
    {texts, state} = sel_texts(state)
    items = Selection.rects(texts, range, state.measure)

    if range == state.sel and items == state.sel_items do
      state
    else
      state = %{state | sel: range, sel_items: items}
      UI.update(state.ui, view_items(state), state.scroll, state.caret_on, :diff)
      state
    end
  end

  # -- focus -----------------------------------------------------------------

  defp focus_step(state, direction) do
    order = Forms.focus_order(state.page.forms.controls)

    case Interact.next_focus(order, state.focus, direction) do
      nil -> state
      cid -> state |> focus(cid, :end) |> relayout() |> ensure_visible(cid)
    end
  end

  # gives `cid` the focus; the caret goes to `where`: :end or an index
  defp focus(state, cid, where) do
    control = control(state, cid)
    UI.focus_page(state.ui)

    caret =
      cond do
        is_integer(where) ->
          where

        control && Forms.editable?(control) ->
          String.length(Forms.current(control, state.page.form_state).value)

        true ->
          0
      end

    state = %{state | focus: cid, caret: caret, menu: nil, fanchor: nil, fdrag: false}
    if control && Forms.editable?(control), do: reset_blink(state), else: stop_blink(state)
  end

  defp blur(state) do
    state |> stop_blink() |> Map.merge(%{focus: nil, fanchor: nil, fdrag: false}) |> relayout()
  end

  defp ensure_visible(state, cid) do
    case state.controls[cid] do
      nil ->
        state

      b ->
        view = UI.client_height(state.ui)

        state =
          cond do
            b.x < state.scroll_x ->
              scroll_x_by(state, b.x - 16 - state.scroll_x)

            b.x + b.w > state.scroll_x + state.width ->
              scroll_x_by(state, b.x + b.w + 16 - state.scroll_x - state.width)

            true ->
              state
          end

        cond do
          b.y < state.scroll ->
            scroll_by(state, b.y - 16 - state.scroll)

          b.y + b.h > state.scroll + view ->
            scroll_by(state, b.y + b.h + 16 - state.scroll - view)

          true ->
            state
        end
    end
  end

  # -- clicking controls -----------------------------------------------------

  defp click_control(state, cid, x, py, count, shift) do
    control = control(state, cid)

    cond do
      control == nil or control.disabled? ->
        state

      Forms.editable?(control) ->
        cur = Forms.current(control, state.page.form_state)

        caret =
          Interact.caret_at(
            state.items,
            cid,
            cur.value,
            cur.scroll,
            Forms.multiline?(control),
            {x, py},
            state.measure
          )

        # shift extends the selection of the field that already has focus
        keep = if shift and state.focus == cid, do: state.fanchor || state.caret

        state
        |> focus(cid, caret)
        |> select_in_field(control, cur.value, caret, keep, count)
        |> relayout()

      control.type in ["checkbox", "radio"] ->
        state |> focus(cid, 0) |> toggle(cid)

      control.tag == "select" ->
        state |> focus(cid, 0) |> relayout() |> open_select(control)

      button?(control) ->
        state |> focus(cid, 0) |> relayout() |> activate(control)

      true ->
        state |> focus(cid, 0) |> relayout()
    end
  end

  # what a click in a field selects: a double click the word, a triple click the line (the
  # whole text of a single-line field); with `keep` the selection grows from there; else a
  # plain click starts one that dragging extends
  defp select_in_field(state, control, value, caret, _keep, count) when count >= 3 do
    {from, to} =
      if Forms.multiline?(control) do
        {line, _} = TextEdit.line_col(value, caret)
        {TextEdit.index_at(value, line, 0), TextEdit.index_at(value, line, String.length(value))}
      else
        {0, String.length(value)}
      end

    %{state | fanchor: from, caret: to}
  end

  defp select_in_field(state, _control, value, caret, _keep, 2) do
    case TextEdit.word_range(value, caret) do
      {from, to} -> %{state | fanchor: from, caret: to}
      nil -> %{state | fanchor: caret}
    end
  end

  defp select_in_field(state, _control, _value, _caret, keep, _count) when keep != nil,
    do: %{state | fanchor: keep, fdrag: true}

  defp select_in_field(state, _control, _value, caret, nil, _count),
    do: %{state | fanchor: caret, fdrag: true}

  # the caret follows the mouse, the anchor stays
  defp drag_field(state, x, py) do
    with %{} = control <- editing_control(state) do
      cur = Forms.current(control, state.page.form_state)

      caret =
        Interact.caret_at(
          state.items,
          control.cid,
          cur.value,
          cur.scroll,
          Forms.multiline?(control),
          {x, py},
          state.measure
        )

      if caret == state.caret, do: state, else: relayout(%{state | caret: caret}, :diff)
    else
      _ -> %{state | fdrag: false}
    end
  end

  defp control_cursor(state, cid) do
    case control(state, cid) do
      nil -> :arrow
      %{disabled?: true} -> :arrow
      control -> if Forms.editable?(control), do: :text, else: :hand
    end
  end

  defp button?(control),
    do: control.tag == "button" or control.type in ["submit", "reset", "button", "image"]

  # -- changing controls -----------------------------------------------------

  defp toggle(state, cid) do
    state.page.form_state
    |> then(&Forms.toggle(&1, state.page.forms.controls, cid))
    |> then(&set_form_state(state, &1))
    |> relayout()
  end

  defp step_option(state, control, delta) do
    state.page.form_state
    |> then(&Forms.step_select(&1, state.page.forms.controls, control.cid, delta))
    |> then(&set_form_state(state, &1))
    |> relayout()
  end

  defp open_select(state, control) do
    cur = Forms.current(control, state.page.form_state)

    case {control.options, state.controls[control.cid]} do
      {[_ | _] = options, %{} = b} ->
        UI.popup_menu(
          state.ui,
          {b.x - state.scroll_x, b.y + b.h - state.scroll},
          Enum.map(options, & &1.label),
          cur.selected
        )

        %{state | menu: control.cid}

      _ ->
        state
    end
  end

  defp choose_option(%{menu: nil} = state, _index), do: state

  defp choose_option(state, index) do
    cid = state.menu
    state = %{state | menu: nil}

    case control(state, cid) do
      %{options: options} when index >= 0 and index < length(options) ->
        state.page.form_state
        |> Forms.put(cid, selected: index)
        |> then(&set_form_state(state, &1))
        |> relayout()

      _ ->
        state
    end
  end

  defp activate(state, %{type: "reset"} = control) do
    state.page.form_state
    |> then(&Forms.reset(&1, state.page.forms.controls, control.form))
    |> then(&set_form_state(state, &1))
    |> relayout()
  end

  defp activate(state, %{type: type} = control) when type in ["submit", "image"],
    do: submit(state, control.form, control.cid)

  defp activate(state, _control), do: state

  defp submit(state, nil, _clicked), do: state

  defp submit(state, form, clicked) do
    page = state.page

    request =
      Forms.submission(
        page.forms.forms,
        page.forms.controls,
        page.form_state,
        form,
        clicked,
        page.url
      )

    opts = if request.method == :post, do: [method: :post, body: request.body], else: []
    load(state, request.url, :push, opts)
  end

  # re-render the controls from `form_state`; layout follows in the caller
  defp set_form_state(state, form_state) do
    page = Page.render(state.page, form_state)
    %{state | page: page, nodes: page.nodes}
  end

  defp control(%{page: nil}, _cid), do: nil
  defp control(state, cid), do: state.page.forms.controls[cid]

  # -- images ----------------------------------------------------------------

  # fetch the page's pictures in the background, a few at a time
  defp start_images(%{page: page} = state) do
    urls = page |> Page.all_image_urls() |> Enum.reject(&Map.has_key?(state.images, &1))

    if urls != [] do
      me = self()
      nonce = state.nonce
      base = page.url

      Task.start(fn ->
        urls
        |> Task.async_stream(
          fn url -> send(me, {:image, nonce, url, Images.fetch(url, base)}) end,
          max_concurrency: 6,
          timeout: 20_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        send(me, {:images_done, nonce, urls})
      end)
    end

    state
  end

  defp schedule_image_layout(%{layout_timer: nil} = state) do
    ref = make_ref()
    Process.send_after(self(), {:image_layout, ref}, 60)
    %{state | layout_timer: ref}
  end

  defp schedule_image_layout(state), do: state

  # -- blink -----------------------------------------------------------------

  defp reset_blink(state), do: schedule_blink(%{state | caret_on: true}, true)

  defp schedule_blink(state, _reset?) do
    ref = make_ref()
    Process.send_after(self(), {:blink, ref}, @blink_ms)
    %{state | blink: ref}
  end

  defp stop_blink(state), do: %{state | blink: nil, caret_on: true}

  # -- helpers -----------------------------------------------------------------

  # viewport description used to evaluate media queries
  defp env(state) do
    %{type: "screen", width: state.width, height: UI.client_height(state.ui), dppx: 1.0}
  end

  defp history_nav(state, fun) do
    case fun.(state.history) do
      {:ok, h} -> load(%{state | history: h}, h.current, :history)
      {:error, _} -> state
    end
  end

  # `mode` is `UI.update/5`'s: `:diff` when the caller knows the page only changed in
  # the items that differ from the last published ones
  defp relayout(state, mode \\ :full) do
    state = fit_scroll(state)
    width = max(UI.client_width(state.ui), 200)

    {items, height} =
      Layout.layout(state.nodes, width, state.measure, UI.client_height(state.ui),
        focus: focus_option(state),
        images: state.images,
        svg_defs: if(state.page, do: state.page.svg_defs, else: %{})
      )

    state = %{
      state
      | items: items,
        height: height,
        width: width,
        links: UI.links(items),
        controls: Layout.controls(items),
        content_w: Layout.content_width(items, width),
        sel: nil,
        sel_anchor: nil,
        drag: false,
        sel_texts: nil,
        sel_items: []
    }

    state = scroll_x_by(state, 0)
    scroll_by(state, 0, mode)
  end

  # After typing into a single-line field only its text and caret move, so patch the
  # laid out items instead of laying out the whole page (see `Layout.patch_field/6`).
  defp relayout_edit(state, _control, nil), do: relayout(state, :diff)

  defp relayout_edit(state, control, old_text) do
    if MapSet.member?(state.page.fixed_width, control.cid),
      do: patch_edit(state, control, old_text),
      else: relayout(state, :diff)
  end

  defp patch_edit(state, control, old_text) do
    state = fit_scroll(state)
    cur = Forms.current(control, state.page.form_state)

    case Layout.patch_field(
           state.items,
           control.cid,
           old_text,
           Forms.visible_text(control, cur),
           focus_option(state),
           state.measure
         ) do
      {:ok, items} ->
        # field items are never links, unless the field sits inside one
        links =
          if Enum.any?(state.links, fn {_, its} -> Enum.any?(its, &(&1[:cid] == control.cid)) end),
             do: UI.links(items),
             else: state.links

        scroll_by(%{state | items: items, links: links}, 0, :diff)

      :error ->
        relayout(state, :diff)
    end
  end

  # what layout needs to draw the ring and caret
  defp focus_option(%{focus: nil}), do: nil

  defp focus_option(state) do
    case control(state, state.focus) do
      nil ->
        nil

      control ->
        {caret, sel} =
          if Forms.editable?(control) do
            cur = Forms.current(control, state.page.form_state)
            multiline? = Forms.multiline?(control)
            pos = &Interact.caret_position(cur.value, &1, cur.scroll, multiline?)

            sel =
              with {from, to} <- TextEdit.selection(state.caret, state.fanchor),
                   do: {pos.(from), pos.(to)}

            {pos.(state.caret), sel}
          else
            {nil, nil}
          end

        %{cid: control.cid, caret: caret, sel: sel}
    end
  end

  # keep the caret inside the field: scroll a long single-line value sideways, a
  # textarea by lines
  defp fit_scroll(%{focus: nil} = state), do: state

  defp fit_scroll(state) do
    with %{} = control <- control(state, state.focus),
         true <- Forms.editable?(control),
         %{font: %{} = font} = bounds <- state.controls[state.focus] do
      cur = Forms.current(control, state.page.form_state)

      scroll =
        if Forms.multiline?(control) do
          {line, _} = TextEdit.line_col(cur.value, state.caret)
          visible = max(div(bounds.h - 6, round(font.size * 1.35)), 1)
          Interact.fit_lines(line, cur.scroll, visible)
        else
          Interact.fit_chars(
            cur.value,
            state.caret,
            cur.scroll,
            bounds.w - 8,
            font,
            state.measure
          )
        end

      if scroll == cur.scroll,
        do: state,
        else: set_form_state(state, Forms.put(state.page.form_state, control.cid, scroll: scroll))
    else
      _ -> state
    end
  end

  # one notch is `wheelDelta` rotation units and scrolls `linesPerAction` lines; precision
  # devices (macOS trackpads, momentum) send many small fractions of a notch
  defp wheel_rotation(rot, delta, lines), do: rot / max(delta, 1) * max(lines, 1) * @wheel_line

  defp drain_wheel(acc, state) do
    receive do
      {:wheel, rot, delta, lines} -> drain_wheel(acc + wheel_rotation(rot, delta, lines), state)
    after
      0 -> {acc, state}
    end
  end

  defp drain_hwheel(acc, state) do
    receive do
      {:hwheel, rot, delta, lines} -> drain_hwheel(acc + wheel_rotation(rot, delta, lines), state)
    after
      0 -> {acc, state}
    end
  end

  defp scroll_x_by(state, delta) do
    max_x = max(state.content_w - state.width, 0)
    sx = state.scroll_x |> Kernel.+(delta) |> max(0) |> min(max_x)

    if sx == state.scroll_x do
      state
    else
      UI.set_scroll_x(state.ui, sx)
      %{state | scroll_x: sx}
    end
  end

  defp scroll_by(state, delta, mode \\ :full) do
    max_scroll = max(state.height - UI.client_height(state.ui), 0)
    scroll = state.scroll |> Kernel.+(delta) |> max(0) |> min(max_scroll)
    UI.update(state.ui, view_items(state), scroll, state.caret_on, mode)
    %{state | scroll: scroll}
  end

  defp sync_buttons(state) do
    UI.enable(state.ui.back, History.can_back?(state.history))
    UI.enable(state.ui.forward, History.can_forward?(state.history))
    state
  end

  defp escape(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
end
