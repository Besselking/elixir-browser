defmodule Browser.SessionJsEventTest do
  use ExUnit.Case, async: true

  test "a page without a script runtime fires no events, with or without event data" do
    state = %{js: nil}

    assert Browser.Session.js_event(state, {:form, 0}, "submit") == {state, false}

    assert Browser.Session.js_event(state, {:form, 0}, "submit", %{"submitter" => nil}) ==
             {state, false}
  end
end
