defmodule Browser.HistoryTest do
  use ExUnit.Case, async: true
  alias Browser.History

  test "back and forward" do
    h = History.new() |> History.visit("a") |> History.visit("b") |> History.visit("c")
    assert {:ok, h} = History.back(h)
    assert h.current == "b"
    assert History.can_forward?(h)
    assert {:ok, h} = History.forward(h)
    assert h.current == "c"
    assert {:error, _} = History.forward(h)
  end

  test "visiting clears forward stack" do
    h = History.new() |> History.visit("a") |> History.visit("b")
    {:ok, h} = History.back(h)
    h = History.visit(h, "z")
    refute History.can_forward?(h)
  end

  test "push adds an entry even at the same address, visit does not" do
    h = History.new() |> History.visit("a") |> History.visit("a")
    refute History.can_back?(h)
    h = History.push(h, "a")
    assert History.can_back?(h)
    assert h.current == "a"
    {:ok, h} = History.back(h)
    h = History.push(h, "z")
    refute History.can_forward?(h)
  end
end
