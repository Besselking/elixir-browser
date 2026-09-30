defmodule Browser.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:browser, :gui, true) do
        [{Browser.Session, []}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Browser.Supervisor)
  end
end
