defmodule Browser.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Browser.CrashReporter.install()
    # the default is two connections per host, which is what a page full of images waits on
    :httpc.set_options(max_sessions: 8, max_keep_alive_length: 20)

    children =
      [Browser.HttpCache, Browser.Cookies, Browser.LocalStorage] ++
        if Application.get_env(:browser, :gui, true) do
          [{Browser.Session, []}]
        else
          []
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: Browser.Supervisor)
  end
end
