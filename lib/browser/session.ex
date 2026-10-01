defmodule Browser.Session do
  @moduledoc """
  Owns the wx environment, history and current document. All wx calls happen
  in this process; page loads run in tasks and report back by message.
  """
  use GenServer
  import Browser.UI, only: [wx: 1, wxMouse: 1, wxCommand: 1, wxSize: 1, wxKey: 1]

  alias Browser.{Fetch, History, Layout, Page, UI}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def navigate(url), do: GenServer.cast(__MODULE__, {:navigate, url})

  @impl true
  def init(_) do
    ui = UI.build()

    state = %{
      ui: ui,
      history: History.new(),
      page: nil,
      nodes: [],
      items: [],
      height: 0,
      scroll: 0,
      width: UI.client_width(ui),
      nonce: 0,
      hover: nil,
      url: nil
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

  defp load(state, url, mode) do
    me = self()
    nonce = state.nonce + 1
    UI.set_status(state.ui, "Loading #{url}…")
    env = env(state)
    Task.start(fn -> send(me, {:loaded, nonce, url, mode, Page.load(url, env)}) end)
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

    state = %{state | history: history, page: page, nodes: page.nodes, url: page.url, scroll: 0}
    {:noreply, state |> relayout() |> sync_buttons()}
  end

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

  def handle_info(wx(event: wxMouse(type: :left_down, x: x, y: y)), state) do
    case UI.link_at(state.items, x, y + state.scroll) do
      nil -> {:noreply, state}
      href -> {:noreply, load(state, Fetch.resolve(state.url, href), :push)}
    end
  end

  def handle_info(wx(event: wxMouse(type: :motion, x: x, y: y)), state) do
    href = UI.link_at(state.items, x, y + state.scroll)

    if href != state.hover do
      UI.set_cursor(state.ui, href != nil)
      UI.set_status(state.ui, if(href, do: Fetch.resolve(state.url, href), else: ""))
    end

    {:noreply, %{state | hover: href}}
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
        {:noreply, relayout(%{state | page: page, nodes: page.nodes})}
    end
  end

  def handle_info(wx(event: wxKey(keyCode: code)), state) do
    page = UI.client_height(state.ui) - 40

    delta =
      case code do
        # up
        315 -> -40
        # down
        317 -> 40
        # page up
        312 -> -page
        # page down
        313 -> page
        # space
        32 -> page
        _ -> 0
      end

    {:noreply, scroll_by(state, delta)}
  end

  def handle_info(_other, state), do: {:noreply, state}

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
    width = max(UI.client_width(state.ui), 200)

    {items, height} =
      Layout.layout(state.nodes, width, UI.measurer(state.ui), UI.client_height(state.ui))

    state = %{state | items: items, height: height, width: width}
    scroll_by(state, 0)
  end

  defp scroll_by(state, delta) do
    max_scroll = max(state.height - UI.client_height(state.ui), 0)
    scroll = state.scroll |> Kernel.+(delta) |> max(0) |> min(max_scroll)
    UI.publish(state.items, scroll)
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
