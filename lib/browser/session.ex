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

  alias Browser.{Fetch, Forms, History, Images, Interact, Layout, Page, TextEdit, UI}

  @blink_ms 530

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
      controls: %{},
      # decoded pictures by url: {:ok, width, height} or :failed
      images: %{},
      layout_timer: nil,
      height: 0,
      scroll: 0,
      width: UI.client_width(ui),
      nonce: 0,
      hover: nil,
      url: nil,
      # form interaction: the focused control, its caret (graphemes), blink state, and
      # the control whose option menu is open
      focus: nil,
      caret: 0,
      caret_on: true,
      blink: nil,
      menu: nil
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
    UI.publish(state.items, state.scroll, state.caret_on)
    UI.refresh(state.ui)
    {:noreply, schedule_blink(state, false)}
  end

  def handle_info({:blink, _stale}, state), do: {:noreply, state}

  # -- wx events -------------------------------------------------------------

  def handle_info(wx(event: {:wxClose, :close_window}), state) do
    System.stop(0)
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

  # a choice from the open <select> menu
  def handle_info(wx(id: id, event: wxCommand(type: :command_menu_selected)), state) do
    {:noreply, choose_option(state, id - UI.menu_base())}
  end

  def handle_info(wx(event: wxMouse(type: :left_down, x: x, y: y)), state) do
    UI.focus_page(state.ui)
    py = y + state.scroll

    case UI.control_at(state.controls, x, py) do
      nil ->
        state = if state.focus, do: blur(state), else: state

        case UI.link_at(state.items, x, py) do
          nil -> {:noreply, state}
          href -> {:noreply, load(state, Fetch.resolve(state.url, href), :push)}
        end

      cid ->
        {:noreply, click_control(state, cid, x, py)}
    end
  end

  def handle_info(wx(event: wxMouse(type: :motion, x: x, y: y)), state) do
    py = y + state.scroll
    href = UI.link_at(state.items, x, py)

    kind =
      case UI.control_at(state.controls, x, py) do
        nil -> if href, do: :hand, else: :arrow
        cid -> control_cursor(state, cid)
      end

    if {href, kind} != state.hover do
      UI.set_cursor(state.ui, kind)
      UI.set_status(state.ui, if(href, do: Fetch.resolve(state.url, href), else: ""))
    end

    {:noreply, %{state | hover: {href, kind}}}
  end

  def handle_info(wx(event: wxMouse(type: :mousewheel, wheelRotation: rot)), state),
    do: {:noreply, scroll_by(state, -rot)}

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

  defp edit_key(state, control, key) do
    cur = Forms.current(control, state.page.form_state)
    multiline? = Forms.multiline?(control)
    opts = [multiline: multiline?, max: control.maxlength]

    result =
      case key do
        :paste -> TextEdit.apply({cur.value, state.caret}, {:char, UI.clipboard_text()}, opts)
        _ -> TextEdit.apply({cur.value, state.caret}, key, opts)
      end

    case {result, key} do
      {{value, caret}, _} ->
        state |> edit(control.cid, value, caret) |> reset_blink() |> relayout()

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
      :page_up -> scroll_by(state, -page)
      :page_down -> scroll_by(state, page)
      {:char, " "} -> scroll_by(state, page)
      :home -> scroll_by(state, -state.scroll)
      :end -> scroll_by(state, state.height)
      _ -> state
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

    state = %{state | focus: cid, caret: caret, menu: nil}
    if control && Forms.editable?(control), do: reset_blink(state), else: stop_blink(state)
  end

  defp blur(state) do
    state |> stop_blink() |> Map.put(:focus, nil) |> relayout()
  end

  defp ensure_visible(state, cid) do
    case state.controls[cid] do
      nil ->
        state

      b ->
        view = UI.client_height(state.ui)

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

  defp click_control(state, cid, x, py) do
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

        state |> focus(cid, caret) |> relayout()

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
          {b.x, b.y + b.h - state.scroll},
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

  defp relayout(state) do
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
        controls: Layout.controls(items)
    }

    scroll_by(state, 0)
  end

  # what layout needs to draw the ring and caret
  defp focus_option(%{focus: nil}), do: nil

  defp focus_option(state) do
    case control(state, state.focus) do
      nil ->
        nil

      control ->
        caret =
          if Forms.editable?(control) do
            cur = Forms.current(control, state.page.form_state)
            Interact.caret_position(cur.value, state.caret, cur.scroll, Forms.multiline?(control))
          end

        %{cid: control.cid, caret: caret}
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

  defp scroll_by(state, delta) do
    max_scroll = max(state.height - UI.client_height(state.ui), 0)
    scroll = state.scroll |> Kernel.+(delta) |> max(0) |> min(max_scroll)
    UI.publish(state.items, scroll, state.caret_on)
    UI.refresh(state.ui)
    %{state | scroll: scroll}
  end

  defp sync_buttons(state) do
    UI.enable(state.ui.back, History.can_back?(state.history))
    UI.enable(state.ui.forward, History.can_forward?(state.history))
    state
  end

  defp escape(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
end
