defmodule Browser do
  @moduledoc """
  A toy native GUI browser. Start with `mix run --no-halt [url]`.
  """

  @home "about:home"

  def home, do: @home

  @doc "Navigate the running browser to `url`."
  def go(url), do: Browser.Session.navigate(url)
end
