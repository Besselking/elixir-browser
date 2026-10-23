defmodule Browser.Windows do
  @moduledoc """
  The browser windows. Each window is a `Browser.Session` process with its own wx frame, tabs,
  history and page; the cookie jar, the caches, local storage and the visited pages are shared.

  This process lives as long as the app does. It owns the tables the painter reads
  (`Browser.UI.init_tables/0`; a window's rows are named by the window and removed when it
  closes), and it knows which windows are open: the app quits when the last one closes.
  """
  use GenServer

  @sup Browser.WindowSup

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Opens a window. Options: `:url` (the home page by default) and `:at` (a `{x, y}` for the frame)."
  def open(opts \\ []) do
    DynamicSupervisor.start_child(@sup, %{
      id: Browser.Session,
      start: {Browser.Session, :start_link, [opts]},
      restart: :temporary
    })
  end

  @doc "Loads `url` in the oldest window."
  def navigate(url) do
    case GenServer.call(__MODULE__, :list) do
      [first | _] -> GenServer.cast(first, {:navigate, url})
      [] -> :ok
    end
  end

  @doc "The windows, oldest first."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Called by a window when it opens."
  def register(pid), do: GenServer.call(__MODULE__, {:register, pid})

  @doc """
  Called by a window that is closing. `:last` when it was the only one (the app quits),
  `:more` when others stay open. The window is no longer in `list/0` after this.
  """
  def closing(pid), do: GenServer.call(__MODULE__, {:closing, pid})

  @doc """
  Quits the app. The VM stops the way it is meant to (applications stop, wx shuts down); a
  hard halt while wx is running ended in a SIGBUS on macOS. If the stop is held up, the halt
  follows after a few seconds.
  """
  def quit do
    Browser.LocalStorage.flush()
    spawn(fn -> Process.sleep(5000) && System.halt(0) end)
    System.stop(0)
  end

  @doc "Sends `msg` to every window except `pid`."
  def broadcast(pid, msg) do
    for other <- list(), other != pid, do: send(other, msg)
    :ok
  end

  @impl true
  def init(_) do
    Browser.UI.init_tables()
    {:ok, %{windows: [], refs: %{}}, {:continue, :first}}
  end

  @impl true
  def handle_continue(:first, state) do
    url = System.get_env("BROWSER_URL") || Browser.home()
    # (a window registers itself here, so this process must not wait for it)
    Task.start(fn -> {:ok, _} = open(url: url) end)
    {:noreply, state}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.windows, state}

  def handle_call({:register, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | windows: state.windows ++ [pid], refs: Map.put(state.refs, pid, ref)}}
  end

  def handle_call({:closing, pid}, _from, state) do
    {ref, refs} = Map.pop(state.refs, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    windows = List.delete(state.windows, pid)
    {:reply, if(windows == [], do: :last, else: :more), %{state | windows: windows, refs: refs}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     %{state | windows: List.delete(state.windows, pid), refs: Map.delete(state.refs, pid)}}
  end
end
