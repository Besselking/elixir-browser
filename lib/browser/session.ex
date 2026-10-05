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

  alias Browser.{
    Fetch,
    Forms,
    History,
    Images,
    Interact,
    Layout,
    Page,
    Selection,
    TextEdit,
    UI,
    Visits
  }

  @blink_ms 530
  # pixels per line of wheel scrolling (3 lines per 120-unit notch = the old 120px per notch)
  # how long the window must stay the same size before the page is laid out for it
  @resize_delay 80

  # pixels per line of a notch of the wheel
  @wheel_line 24

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def navigate(url), do: GenServer.cast(__MODULE__, {:navigate, url})

  @impl true
  def init(_) do
    ui = UI.build()
    cache = UI.new_measure_cache()

    state = %{
      ui: ui,
      measure: UI.measurer(ui, cache),
      # the same widths for a layout running in the background, which needs a DC of its own
      measure_bg: UI.measurer(ui, cache),
      # `ex` and `ch` read from the fonts, for the cascade
      font_units: UI.font_units(cache),
      # a layout running in the background after a resize: {ref, pid}
      layout_job: nil,
      # the page a script's changes are being turned into (`start_page_job/2`), and the newest
      # tree that arrived meanwhile
      page_job: nil,
      # a `#fragment` to scroll to once the page is laid out: `{name, give up at}`
      fragment: nil,
      page_pending: nil,
      # what the user typed into controls (by element number): it stays as it is when a script
      # changes the page
      page_edits: %{},
      # the page's JavaScript runtime, when it has scripts
      js: nil,
      history: History.new(),
      # pages visited, kept between runs, and what the address bar is suggesting from them:
      # `%{items: [{url, title}], idx: highlighted or -1, typed: what the user typed}`
      visits: Visits.load(),
      suggest: nil,
      url_text: nil,
      page: nil,
      nodes: [],
      items: [],
      # links indexed by band (UI.links/1), so hover needn't scan every item
      links: %{},
      controls: %{},
      # the same without controls in sticky or fixed boxes, which are found by `UI.sticky_hit/4`
      hit_controls: %{},
      sticky: [],
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
      # the timer that lays the page out once resizing stops: {ref, timer}
      resize_timer: nil,
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
    state = stop_js(state)

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
        :replace -> History.replace(state.history, page.url)
        :history -> state.history
      end

    state = state |> set_url_text(page.url) |> remember(result, mode, page)
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
        page_edits: %{},
        fragment: pending_fragment(page.url),
        focus: nil,
        caret: 0,
        controls: %{},
        # the old page stays on screen until the new one is laid out: nothing on it is live
        links: %{},
        hit_controls: %{},
        sticky: [],
        menu: nil
      })

    # the pictures download while the page is laid out in the background
    {:noreply, state |> start_images() |> start_layout_job() |> start_js() |> sync_buttons()}
  end

  # a runtime's scripts have run
  def handle_info({:js_reply, nonce, pid, reply}, %{nonce: nonce, js: pid} = state),
    do: {:noreply, apply_js(state, reply)}

  def handle_info({:js_reply, _, _, _}, state), do: {:noreply, state}

  # a timer or a promise changed the page after the call that started it had returned
  def handle_info({:js_async, pid, reply}, %{js: pid} = state),
    do: {:noreply, apply_js(state, reply)}

  def handle_info({:js_async, _, _}, state), do: {:noreply, state}

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

    state = put_in(state, [:images, url], info)

    cond do
      # the layout that is running picks up (or checks) the picture when it is done
      state.layout_job != nil ->
        {:noreply, state}

      image_layout_needed?(state.page, url, info) ->
        {:noreply, schedule_image_layout(state)}

      true ->
        # every <img> showing it already has its final box: only the picture is missing
        UI.refresh_images(state.ui, state.items, url, state.scroll, &moved_on_screen?/1)
        {:noreply, state}
    end
  end

  def handle_info({:image, _stale, _url, _result}, state), do: {:noreply, state}

  # a fetch that was killed on timeout never reports, so mark what is still missing
  def handle_info({:images_done, nonce, urls}, %{nonce: nonce} = state) do
    missing = Enum.reject(urls, &Map.has_key?(state.images, &1))
    images = Enum.reduce(missing, state.images, &Map.put(&2, &1, :failed))
    state = %{state | images: images}
    {:noreply, if(missing == [], do: state, else: schedule_image_layout(state))}
  end

  def handle_info({:images_done, _stale, _urls}, state), do: {:noreply, state}

  # several pictures usually arrive together: lay out once for the batch
  def handle_info({:image_layout, ref}, %{layout_timer: ref, layout_job: nil} = state),
    do: {:noreply, start_layout_job(%{state | layout_timer: nil})}

  # a layout is running in the background: the pictures are picked up when it is done
  def handle_info({:image_layout, ref}, %{layout_timer: ref} = state),
    do: {:noreply, schedule_image_layout(%{state | layout_timer: nil})}

  def handle_info({:image_layout, _stale}, state), do: {:noreply, state}

  # -- blinking caret --------------------------------------------------------

  def handle_info({:blink, ref}, %{blink: ref} = state) do
    state = %{state | caret_on: not state.caret_on}
    UI.update(state.ui, state.items, state.sel_items, state.scroll, state.caret_on, :diff)
    {:noreply, schedule_blink(state, false)}
  end

  def handle_info({:blink, _stale}, state), do: {:noreply, state}

  # -- wx events -------------------------------------------------------------

  def handle_info(wx(event: {:wxClose, :close_window}), state) do
    # An orderly shutdown frees the toolkit's objects while its event loop is still
    # running, which crashes the wx driver (a "quit unexpectedly" dialog on macOS).
    # Only localStorage may still be waiting to be written; then leave straight away.
    Browser.LocalStorage.flush()
    System.halt(0)
    {:noreply, state}
  end

  def handle_info(
        wx(obj: obj, event: wxCommand(type: :command_text_enter, cmdString: str)),
        state
      )
      when obj == state.ui.url,
      do: {:noreply, load(state, Fetch.normalize(to_string(str)), :push)}

  # typing in the address bar suggests visited pages (not when the text was set by the browser)
  def handle_info(
        wx(obj: obj, event: wxCommand(type: :command_text_updated, cmdString: str)),
        state
      )
      when obj == state.ui.url do
    text = to_string(str)

    if text == state.url_text do
      {:noreply, state}
    else
      items = Visits.suggest(state.visits, text)
      UI.show_suggestions(state.ui, items)
      {:noreply, %{state | suggest: %{items: items, idx: -1, typed: text}, url_text: text}}
    end
  end

  def handle_info({:url_key, 27}, state) do
    UI.hide_suggestions(state.ui)
    {:noreply, %{state | suggest: nil}}
  end

  def handle_info({:url_key, key}, %{suggest: %{items: [_ | _]} = sg} = state) do
    n = length(sg.items)
    idx = if key == 317, do: min(sg.idx + 1, n - 1), else: max(sg.idx - 1, -1)
    UI.select_suggestion(state.ui, idx)

    text = if idx == -1, do: sg.typed, else: elem(Enum.at(sg.items, idx), 0)
    UI.put_url_text(state.ui, text)
    {:noreply, %{state | suggest: %{sg | idx: idx}, url_text: text}}
  end

  def handle_info({:url_key, _}, state), do: {:noreply, state}

  def handle_info(
        wx(obj: obj, event: wxCommand(type: :command_listbox_selected, commandInt: i)),
        state
      )
      when obj == state.ui.suggest do
    case state.suggest && Enum.at(state.suggest.items, i) do
      {url, _} ->
        UI.hide_suggestions(state.ui)
        {:noreply, load(%{state | suggest: nil}, url, :push)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(wx(obj: obj, event: wxCommand(type: :command_button_clicked)), state) do
    ui = state.ui

    cond do
      obj == ui.back ->
        {:noreply, history_step(state, -1)}

      obj == ui.forward ->
        {:noreply, history_step(state, 1)}

      obj == ui.reload ->
        {:noreply, (state.url && load(state, state.url, :history, cache: :reload)) || state}

      true ->
        {:noreply, state}
    end
  end

  # Quit (Cmd+Q and the application menu's item)
  def handle_info(wx(id: 5006, event: wxCommand(type: :command_menu_selected)), _state) do
    Browser.LocalStorage.flush()
    System.halt(0)
  end

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
    UI.hide_suggestions(state.ui)
    state = %{state | suggest: nil}

    x = wx_x + state.scroll_x
    UI.focus_page(state.ui)
    py = y + state.scroll
    {count, state} = register_click(state, x, y, :down)

    case UI.sticky_hit(state.sticky, x, y, state.scroll) do
      {:control, cid, spy} ->
        {:noreply, click_control(state, cid, x, spy, count, shift)}

      {:link, href} ->
        {:noreply, follow(state, href)}

      # a click on a sticky or fixed box that is neither: it does not reach the page below
      :cover ->
        {:noreply, if(state.focus, do: blur(state), else: state)}

      nil ->
        case UI.control_at(state.hit_controls, x, py) do
          nil ->
            state = if state.focus, do: blur(state), else: state

            case UI.link_at(state.links, x, py) do
              nil -> {:noreply, page_click(state, x, py, count, shift)}
              href -> {:noreply, follow(state, href)}
            end

          cid ->
            {:noreply, click_control(state, cid, x, py, count, shift)}
        end
    end
  end

  def handle_info(wx(event: wxMouse(type: :left_dclick, x: wx_x, y: y)), state) do
    x = wx_x + state.scroll_x
    py = y + state.scroll
    {count, state} = register_click(state, x, y, :dclick)

    case UI.sticky_hit(state.sticky, x, y, state.scroll) do
      {:control, cid, spy} ->
        {:noreply, click_control(state, cid, x, spy, count, false)}

      hit when hit != nil ->
        {:noreply, state}

      nil ->
        case UI.control_at(state.hit_controls, x, py) do
          nil ->
            if UI.link_at(state.links, x, py) == nil,
              do: {:noreply, select_unit(state, x, py, count)},
              else: {:noreply, state}

          cid ->
            {:noreply, click_control(state, cid, x, py, count, false)}
        end
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
    {texts, state} = sel_texts(state)

    {href, kind} =
      case UI.sticky_hit(state.sticky, x, y, state.scroll) do
        {:link, href} ->
          {href, :hand}

        {:control, cid, _} ->
          {nil, control_cursor(state, cid)}

        :cover ->
          {nil, :arrow}

        nil ->
          href = UI.link_at(state.links, x, py)

          kind =
            case UI.control_at(state.hit_controls, x, py) do
              nil ->
                cond do
                  href -> :hand
                  Selection.over_text?(texts, x, py) -> :text
                  true -> :arrow
                end

              cid ->
                control_cursor(state, cid)
            end

          {href, kind}
      end

    {old_href, old_kind} = state.hover
    if kind != old_kind, do: UI.set_cursor(state.ui, kind)

    if href != old_href,
      do: UI.set_status(state.ui, if(href, do: Fetch.resolve(base(state), href), else: ""))

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

  # A window being dragged to a new size sends a stream of size events, and laying the page out
  # for each one would put the session minutes behind. Every event only restarts a timer; the
  # page is laid out once, for the size the window has when the events stop.
  def handle_info(wx(event: wxSize(size: _)), state) do
    state = cancel_layout_job(state)

    case state.resize_timer do
      {_ref, timer} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    ref = make_ref()
    timer = Process.send_after(self(), {:resize, ref}, @resize_delay)
    {:noreply, %{state | resize_timer: {ref, timer}}}
  end

  def handle_info({:resize, ref}, %{resize_timer: {ref, _}} = state) do
    state = %{state | resize_timer: nil}
    w = UI.client_width(state.ui)

    cond do
      w == state.width ->
        {:noreply, state}

      state.page == nil ->
        {:noreply, %{state | width: w}}

      true ->
        {:noreply, start_layout_job(%{state | width: w})}
    end
  end

  # The page is restyled and laid out for the new size in a process of its own, so the window
  # keeps answering (and a further resize just throws the work away) while a big page lays out.
  def handle_info(
        {:layout_done, ref, base, page, items, height, width, used},
        %{layout_job: {ref, _}} = state
      ) do
    state = %{state | layout_job: nil}

    state =
      if state.page.ver == base do
        state = fit_scroll(%{state | page: page, nodes: page.nodes})
        state = apply_layout(state, items, height, width, :full)
        # pictures that arrived while it ran: it laid them out as still loading, which
        # is right when their boxes do not depend on them
        late = for {url, info} <- state.images, Map.get(used, url) != info, do: {url, info}

        if Enum.any?(late, fn {url, info} -> image_layout_needed?(page, url, info) end),
          do: schedule_image_layout(state),
          else: state
      else
        # the page changed meanwhile (typing, a new page): the result is stale
        relayout(state)
      end

    # a new viewport can switch on other background images
    {:noreply, start_images(state)}
  end

  def handle_info({:layout_done, _stale, _, _, _, _, _, _}, state), do: {:noreply, state}

  # a script's changes to the page are laid out
  def handle_info(
        {:page_done, ref, nonce, page, items, height, width, used},
        %{page_job: {ref, _}} = state
      ) do
    pending = state.page_pending
    edits = state.page_edits
    state = %{state | page_job: nil, page_pending: nil}

    state =
      if nonce == state.nonce and state.page != nil do
        # the new page's controls may be numbered differently: the focus and what the user
        # typed meanwhile follow the element
        old_nids = Page.cid_nids(state.page)
        new_cids = page |> Page.cid_nids() |> Map.new(fn {cid, nid} -> {nid, cid} end)
        focus = with nid when nid != nil <- old_nids[state.focus], do: new_cids[nid]

        carried =
          for {nid, entry} <- edits, new_cid = new_cids[nid], into: %{}, do: {new_cid, entry}

        page = if carried == %{}, do: page, else: Page.render(page, carried)
        state = %{state | page: page, nodes: page.nodes, focus: focus, controls: %{}}
        state = cancel_layout_job(state)

        # what the user typed meanwhile is not in what the job laid out: lay out again
        state =
          if carried == %{},
            do: apply_layout(state, items, height, width, :full),
            else: start_layout_job(state)

        late = for {url, info} <- state.images, Map.get(used, url) != info, do: {url, info}

        cond do
          width != max(UI.client_width(state.ui), 200) ->
            relayout(state)

          Enum.any?(late, fn {url, info} -> image_layout_needed?(page, url, info) end) ->
            schedule_image_layout(state)

          true ->
            state
        end
      else
        state
      end

    state = if pending, do: start_page_job(state, pending), else: state
    {:noreply, start_images(state)}
  end

  def handle_info({:page_done, _, _, _, _, _, _, _}, state), do: {:noreply, state}

  # a timer for a size that has since changed again
  def handle_info({:resize, _stale}, state), do: {:noreply, state}

  def handle_info(wx(event: event), state) when elem(event, 0) == :wxKey do
    key = event |> UI.key_event() |> Interact.key()
    {:noreply, on_key(state, key)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- keyboard --------------------------------------------------------------

  # A key goes to the page's scripts first (`keydown`, then `keypress` for characters and Enter),
  # and does what it does by default unless one of them called `preventDefault`.
  defp on_key(%{js: nil} = state, key), do: do_key(state, key)

  defp on_key(state, key) when key in [:ignore, :copy, :select_all, :cut, :paste],
    do: do_key(state, key)

  defp on_key(state, key) do
    {state, prevented?} = key_event(state, "keydown", key)

    {state, prevented?} =
      if not prevented? and press?(key),
        do: key_event(state, "keypress", key),
        else: {state, prevented?}

    if prevented?, do: state, else: do_key(state, key)
  end

  defp press?({:char, _}), do: true
  defp press?(:enter), do: true
  defp press?(_), do: false

  defp key_event(state, type, key) do
    target = if state.focus, do: {:control, state.focus}, else: :document

    reply =
      Browser.JS.Runtime.dispatch(
        state.js,
        target,
        type,
        key_props(key),
        controls_snapshot(state)
      )

    {apply_js(state, reply), reply.prevented}
  end

  # the properties of a keyboard event
  defp key_props(key) do
    {shift?, key} = with {:select, dir} <- key, do: {true, dir}, else: (k -> {false, k})

    {name, code} =
      case key do
        {:char, c} -> {c, c |> String.upcase() |> String.to_charlist() |> hd()}
        :enter -> {"Enter", 13}
        :backspace -> {"Backspace", 8}
        :delete -> {"Delete", 46}
        :tab -> {"Tab", 9}
        :shift_tab -> {"Tab", 9}
        :escape -> {"Escape", 27}
        :left -> {"ArrowLeft", 37}
        :up -> {"ArrowUp", 38}
        :right -> {"ArrowRight", 39}
        :down -> {"ArrowDown", 40}
        :home -> {"Home", 36}
        :end -> {"End", 35}
        :page_up -> {"PageUp", 33}
        :page_down -> {"PageDown", 34}
        _ -> {"Unidentified", 0}
      end

    %{
      "key" => name,
      "code" => name,
      "keyCode" => code * 1.0,
      "which" => code * 1.0,
      "shiftKey" => shift? or key == :shift_tab,
      "ctrlKey" => false,
      "altKey" => false,
      "metaKey" => false,
      "repeat" => false
    }
  end

  defp do_key(state, :ignore), do: state

  defp do_key(state, key) when key in [:copy, :select_all, :cut] do
    case editing_control(state) do
      nil -> if key == :cut, do: state, else: page_selection_key(state, key)
      control -> edit_key(state, control, key)
    end
  end

  defp do_key(%{focus: nil} = state, key) when key in [:tab, :shift_tab],
    do: focus_step(state, if(key == :tab, do: :forward, else: :backward))

  defp do_key(%{focus: nil} = state, key), do: page_key(state, key)

  defp do_key(state, key) do
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
    state = set_form_state(state, form_state) |> Map.put(:caret, caret)
    js_notify(state, cid, ["input"])
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
      UI.update(state.ui, state.items, state.sel_items, state.scroll, state.caret_on, :diff)
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

      # a control in a sticky or fixed box is in the window wherever the page is
      %{stick: stick} when stick != nil ->
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

      # opening or closing a <details>: the summary takes no focus
      control.type == "summary" ->
        toggle(state, cid)

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
    state =
      state.page.form_state
      |> then(&Forms.toggle(&1, state.page.forms.controls, cid))
      |> then(&set_form_state(state, &1))
      |> relayout()

    case control(state, cid) do
      %{type: type} when type in ["checkbox", "radio"] ->
        js_notify(state, cid, ["click", "input", "change"])

      _ ->
        state
    end
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
        shift = UI.stick_shift(%{stick: b.stick}, state.scroll)

        UI.popup_menu(
          state.ui,
          {b.x - state.scroll_x, b.y + b.h - state.scroll + shift},
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

  defp activate(state, %{type: type} = control)
       when type in ["button"] or control.tag == "button" do
    {state, _} = js_event(state, {:control, control.cid}, "click")
    state
  end

  defp activate(state, _control), do: state

  defp submit(state, form, clicked) do
    # scripts may handle the click or the submission themselves
    {state, prevented} =
      case if(clicked, do: js_event(state, {:control, clicked}, "click"), else: {state, false}) do
        {state, true} -> {state, true}
        {state, false} when form == nil -> {state, true}
        {state, false} -> js_event(state, {:form, form}, "submit")
      end

    if prevented, do: state, else: navigate_form(state, form, clicked)
  end

  defp navigate_form(state, form, clicked) do
    page = state.page

    request =
      Forms.submission(
        page.forms.forms,
        page.forms.controls,
        page.form_state,
        form,
        clicked,
        page.url,
        page.base || page.url
      )

    opts = if request.method == :post, do: [method: :post, body: request.body], else: []
    load(state, request.url, :push, [initiator: state.url] ++ opts)
  end

  # re-render the controls from `form_state`; layout follows in the caller
  defp set_form_state(state, form_state) do
    edits =
      if state.js == nil do
        state.page_edits
      else
        nids = Page.cid_nids(state.page)

        for {cid, entry} <- form_state,
            Map.get(state.page.form_state, cid) != entry,
            nid = nids[cid],
            reduce: state.page_edits,
            do: (acc -> Map.put(acc, nid, entry))
      end

    page = Page.render(state.page, form_state)
    %{state | page: page, nodes: page.nodes, page_edits: edits}
  end

  # -- the page's scripts ------------------------------------------------------

  # what the page's relative addresses resolve against
  defp base(%{page: %{base: base}}) when is_binary(base), do: base
  defp base(state), do: state.url

  defp start_js(%{page: page} = state) do
    if Page.scripts?(page) do
      info = %{
        url: page.url,
        base: page.base || page.url,
        width: state.width,
        height: UI.client_height(state.ui),
        history_before: length(state.history.back),
        fetch: &Fetch.load(&1, initiator: page.url),
        request: &Fetch.load(&1, [initiator: page.url] ++ &2)
      }

      pid = Browser.JS.Runtime.start(page.raw, info)
      me = self()
      nonce = state.nonce

      Task.start(fn ->
        send(me, {:js_reply, nonce, pid, Browser.JS.Runtime.run_scripts(pid)})
      end)

      %{state | js: pid}
    else
      state
    end
  end

  defp stop_js(state) do
    state = cancel_page_job(state)

    case state.js do
      nil ->
        state

      pid ->
        Browser.JS.Runtime.stop(pid)
        %{state | js: nil}
    end
  end

  defp cancel_page_job(%{page_job: nil} = state), do: %{state | page_pending: nil}

  defp cancel_page_job(%{page_job: {_ref, pid}} = state) do
    Process.exit(pid, :kill)
    %{state | page_job: nil, page_pending: nil}
  end

  # the live values of the controls, which scripts read
  defp controls_snapshot(%{page: page}) do
    for {cid, control} <- page.forms.controls, into: %{} do
      cur = Forms.current(control, page.form_state)
      {cid, %{value: cur.value, checked: cur.checked, selected: cur.selected}}
    end
  end

  # fires an event in the page's scripts: -> {state, default prevented?}
  defp js_event(%{js: nil} = state, _target, _type), do: {state, false}

  defp js_event(state, target, type) do
    reply = Browser.JS.Runtime.dispatch(state.js, target, type, %{}, controls_snapshot(state))
    {apply_js(state, reply), reply.prevented}
  end

  defp js_notify(state, cid, types) do
    Enum.reduce(types, state, fn type, state ->
      state |> js_event({:control, cid}, type) |> elem(0)
    end)
  end

  # what a script did: address changes, navigations, and a changed document
  defp apply_js(state, reply) do
    state = Enum.reduce(reply.outbox, state, &js_effect/2)

    if reply.dirty and reply.raw != nil and state.page != nil,
      do: start_page_job(state, reply.raw),
      else: state
  end

  # The changed tree is indexed, styled and laid out in a process of its own, so a script that
  # keeps changing the page (an animation, a scroll listener) does not stop the window from
  # scrolling and answering. Trees that arrive while it runs are replaced by the newest one.
  defp start_page_job(%{page_job: nil} = state, raw) do
    me = self()
    ref = make_ref()
    wx_env = :wx.get_env()
    base = state.page
    env = env(state)
    nonce = state.nonce
    width = max(UI.client_width(state.ui), 200)
    view_h = UI.client_height(state.ui)
    images = state.images
    measure = state.measure_bg

    pid =
      :erlang.spawn_opt(
        fn ->
          :wx.set_env(wx_env)
          page = Page.from_raw(base, raw, env)

          {items, height} =
            Layout.layout(page.nodes, width, measure, view_h,
              metrics: &measure.(:content_height, &1),
              images: images,
              svg_defs: page.svg_defs
            )

          send(me, {:page_done, ref, nonce, page, items, height, width, images})
        end,
        min_heap_size: 2_000_000
      )

    %{state | page_job: {ref, pid}, page_pending: nil}
  end

  defp start_page_job(state, raw), do: %{state | page_pending: raw}

  defp js_effect({:history, kind, url}, state) do
    history =
      if kind == :push,
        do: History.push(state.history, url),
        else: History.replace(state.history, url)

    state = set_url_text(state, url)
    page = state.page && %{state.page | url: url}
    sync_buttons(%{state | history: history, url: url, page: page})
  end

  defp js_effect({:navigate, url, mode}, state), do: load(state, url, mode, initiator: state.url)

  # `location.hash = ...`: an entry in the page's history, and the page scrolls to the fragment
  defp js_effect({:hash, url, mode}, state) do
    state = js_effect({:history, mode, url}, state)

    case Fetch.split_fragment(url) do
      {_, fragment} when fragment not in [nil, ""] ->
        scroll_to_fragment(%{state | fragment: {fragment, deadline()}})

      _ ->
        state
    end
  end

  defp js_effect({:scroll_to, x, y}, state) do
    state
    |> scroll_x_by(round(x) - state.scroll_x)
    |> scroll_by(round(y) - state.scroll)
  end

  # `form.submit()` and `requestSubmit()`: the form goes the way a click on its button sends it
  defp js_effect({:submit, fid}, state) when is_integer(fid), do: navigate_form(state, fid, nil)

  defp js_effect({:reload}, state), do: load(state, state.url, :history)
  defp js_effect({:history_go, 0}, state), do: load(state, state.url, :history)
  defp js_effect({:history_go, n}, state), do: history_step(state, n)
  defp js_effect(_other, state), do: state

  defp control(%{page: nil}, _cid), do: nil
  defp control(state, cid), do: state.page.forms.controls[cid]

  # -- images ----------------------------------------------------------------

  # fetch the page's pictures in the background, a few at a time
  defp start_images(%{page: page} = state) do
    urls = page |> Page.all_image_urls() |> Enum.reject(&Map.has_key?(state.images, &1))

    if urls != [] do
      me = self()
      nonce = state.nonce
      base = page.base || page.url

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

  # A decoded bitmap whose <img> boxes do not depend on its size (and that no style uses
  # as a background) only needs repainting. Anything else, a failed picture included,
  # changes the page.
  defp image_layout_needed?(%Page{} = page, url, {:ok, _, _}) do
    not (Layout.image_size_fixed?(page.nodes, url) and not Page.background_url?(page, url))
  end

  defp image_layout_needed?(_page, _url, _info), do: true

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
    %{
      type: "screen",
      width: state.width,
      height: UI.client_height(state.ui),
      dppx: 1.0,
      font_units: state.font_units
    }
  end

  # `n` entries back (negative) or forward. Entries the page made itself with `pushState` or
  # fragments are visited without loading anything, and the page hears `popstate`.
  defp history_step(state, n) do
    case step_history(state.history, n) do
      {:ok, h} ->
        reply = state.js && state.page && Browser.JS.Runtime.traverse(state.js, n)

        if reply && Map.get(reply, :moved) do
          state = set_url_text(%{state | history: h, url: h.current}, h.current)
          state = %{state | page: state.page && %{state.page | url: h.current}}
          state |> sync_buttons() |> apply_js(reply)
        else
          load(%{state | history: h}, h.current, :history, cache: :history)
        end

      :error ->
        state
    end
  end

  defp step_history(h, 0), do: {:ok, h}

  defp step_history(h, n) do
    fun = if n < 0, do: &History.back/1, else: &History.forward/1

    with {:ok, h} <- fun.(h) do
      step_history(h, n - div(n, abs(n)))
    else
      _ -> :error
    end
  end

  # `mode` is `UI.update/6`'s: `:diff` when the caller knows the page only changed in
  # the items that differ from the last published ones
  defp relayout(state, mode \\ :full) do
    state = fit_scroll(state)
    width = max(UI.client_width(state.ui), 200)

    {items, height} =
      Layout.layout(state.nodes, width, state.measure, UI.client_height(state.ui),
        metrics: &state.measure.(:content_height, &1),
        focus: focus_option(state),
        images: state.images,
        svg_defs: if(state.page, do: state.page.svg_defs, else: %{})
      )

    apply_layout(state, items, height, width, mode)
  end

  defp start_layout_job(state) do
    state = cancel_layout_job(state)
    me = self()
    ref = make_ref()
    wx_env = :wx.get_env()
    base = state.page
    env = env(state)
    width = max(UI.client_width(state.ui), 200)
    view_h = UI.client_height(state.ui)
    focus = focus_option(state)
    images = state.images
    measure = state.measure_bg

    # a layout allocates a lot: a big initial heap saves it growing the heap by many collections
    pid =
      :erlang.spawn_opt(
        fn ->
          :wx.set_env(wx_env)
          page = Page.restyle(base, env)

          {items, height} =
            Layout.layout(page.nodes, width, measure, view_h,
              metrics: &measure.(:content_height, &1),
              focus: focus,
              images: images,
              svg_defs: page.svg_defs
            )

          send(me, {:layout_done, ref, base.ver, page, items, height, width, images})
        end,
        min_heap_size: 2_000_000
      )

    %{state | layout_job: {ref, pid}}
  end

  defp cancel_layout_job(%{layout_job: nil} = state), do: state

  defp cancel_layout_job(%{layout_job: {_ref, pid}} = state) do
    Process.exit(pid, :kill)
    %{state | layout_job: nil}
  end

  defp apply_layout(state, items, height, width, mode) do
    state = %{
      state
      | items: items,
        height: height,
        width: width,
        links: UI.links(items),
        controls: Layout.controls(items),
        hit_controls: Layout.controls(Enum.reject(items, &moved_on_screen?/1)),
        sticky: items |> Enum.filter(&moved_on_screen?/1) |> Enum.sort_by(&Map.get(&1, :z, 0)),
        content_w: Layout.content_width(items, width),
        sel: nil,
        sel_anchor: nil,
        drag: false,
        sel_texts: nil,
        sel_items: []
    }

    state = scroll_x_by(state, 0)
    state = scroll_by(state, 0, mode)
    send_layout(state)
    scroll_to_fragment(state)
  end

  # -- #fragments ---------------------------------------------------------------

  # a link to the same document with a fragment only moves within it
  defp follow(state, href) do
    url = Fetch.resolve(base(state), href)
    {target, fragment} = Fetch.split_fragment(url)
    {here, _} = Fetch.split_fragment(state.url || "")

    if fragment != nil and target == here and state.page != nil,
      do: go_to_fragment(state, url, fragment),
      else: load(state, url, :push, initiator: state.url)
  end

  # the address bar shows `text`; the change is not something the user typed
  defp set_url_text(state, text) do
    UI.set_url_text(state.ui, text)
    Browser.CrashReporter.set_page(text)
    %{state | url_text: text, suggest: nil}
  end

  # a page that loaded is added to the history (an error page, or back/forward, is not)
  defp remember(state, {:ok, _}, :push, page) do
    visits = Visits.record(state.visits, page.url, page.title)
    Task.start(fn -> Visits.save(visits) end)
    %{state | visits: visits}
  end

  defp remember(state, _result, _mode, _page), do: state

  defp go_to_fragment(state, url, fragment) do
    state = set_url_text(state, url)

    state =
      %{
        state
        | history: History.visit(state.history, url),
          url: url,
          page: %{state.page | url: url},
          fragment: {fragment, deadline()}
      }

    state =
      if state.js do
        apply_js(state, Browser.JS.Runtime.fragment(state.js, url))
      else
        state
      end

    state |> sync_buttons() |> scroll_to_fragment()
  end

  defp decode_fragment(raw) do
    URI.decode(raw)
  rescue
    ArgumentError -> raw
  end

  defp pending_fragment(url) do
    case Fetch.split_fragment(url) do
      {_, nil} -> nil
      {_, fragment} -> {fragment, deadline()}
    end
  end

  # the page may still be growing (a script builds the section): keep trying for a while
  defp deadline, do: System.monotonic_time(:millisecond) + 4000

  defp scroll_to_fragment(%{fragment: nil} = state), do: state

  defp scroll_to_fragment(%{fragment: {raw, until}} = state) do
    name = decode_fragment(raw)

    y =
      if name in ["", "top"] do
        0
      else
        rects = Browser.Nids.rects(state.items, Browser.Nids.parents(state.page.pruned || []))
        Browser.Nids.anchor_y(state.page.pruned || [], rects, name)
      end

    cond do
      y != nil ->
        state = %{state | fragment: nil}
        scroll_by(state, round(y) - state.scroll)

      System.monotonic_time(:millisecond) > until ->
        %{state | fragment: nil}

      true ->
        state
    end
  end

  # the scripts learn where the elements are (and how far the page is scrolled)
  defp send_layout(%{js: nil}), do: :ok
  defp send_layout(%{page: nil}), do: :ok

  defp send_layout(%{js: pid, page: page} = state) do
    rects = Browser.Nids.rects(state.items, Browser.Nids.parents(page.pruned || []))

    Browser.JS.Runtime.layout(
      pid,
      rects,
      state.scroll_x,
      state.scroll,
      {state.content_w, state.height}
    )
  end

  defp notify_scroll(%{js: nil}), do: :ok

  defp notify_scroll(%{js: pid} = state),
    do: Browser.JS.Runtime.scrolled(pid, state.scroll_x, state.scroll)

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

        sticky = items |> Enum.filter(&moved_on_screen?/1) |> Enum.sort_by(&Map.get(&1, :z, 0))
        scroll_by(%{state | items: items, links: links, sticky: sticky}, 0, :diff)

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
      state = %{state | scroll_x: sx}
      notify_scroll(state)
      state
    end
  end

  # sticky, fixed and transformed items are drawn somewhere else than they were laid out
  defp moved_on_screen?(item), do: Map.has_key?(item, :stick) or Map.has_key?(item, :xform)

  defp scroll_by(state, delta, mode \\ :full) do
    max_scroll = max(state.height - UI.client_height(state.ui), 0)
    old = state.scroll
    scroll = state.scroll |> Kernel.+(delta) |> max(0) |> min(max_scroll)
    UI.update(state.ui, state.items, state.sel_items, scroll, state.caret_on, mode)
    state = %{state | scroll: scroll}
    if scroll != old, do: notify_scroll(state)
    state
  end

  defp sync_buttons(state) do
    UI.enable(state.ui.back, History.can_back?(state.history))
    UI.enable(state.ui.forward, History.can_forward?(state.history))
    state
  end

  defp escape(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
end
