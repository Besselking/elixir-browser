defmodule Browser.VisitsTest do
  use ExUnit.Case, async: true
  alias Browser.Visits

  @now 1_800_000_000

  defp visits do
    %{}
    |> Visits.record("https://elixir-lang.org/", "The Elixir programming language", @now - 100)
    |> Visits.record("https://hexdocs.pm/elixir/Enum.html", "Enum — Elixir", @now - 50)
    |> Visits.record("https://www.example.com/elixir", "Example", @now - 10)
    |> Visits.record("https://elixir-lang.org/", "The Elixir programming language", @now - 5)
  end

  test "records counts and keeps only web addresses" do
    v = visits()
    assert v["https://elixir-lang.org/"].count == 2
    assert Visits.record(v, "about:home", "Home", @now) == v
    assert Visits.record(v, "file:///tmp/x.html", "x", @now) == v
  end

  test "addresses starting with the text come first, then ones containing it, then titles" do
    urls = for {u, _} <- Visits.suggest(visits(), "elixir", 8, @now), do: u
    assert hd(urls) == "https://elixir-lang.org/"
    assert Enum.sort(urls) == Enum.sort(Map.keys(visits()))

    assert [{"https://hexdocs.pm/elixir/Enum.html", _}] =
             Visits.suggest(visits(), "hexdocs", 8, @now)

    assert [{"https://hexdocs.pm/elixir/Enum.html", _}] =
             Visits.suggest(visits(), "enum", 8, @now)
  end

  test "scheme and www are ignored, case too, and nothing typed suggests nothing" do
    assert [{"https://www.example.com/elixir", _}] =
             Visits.suggest(visits(), "WWW.example", 8, @now)

    assert [{"https://elixir-lang.org/", _}] =
             Visits.suggest(visits(), "https://elixir-l", 8, @now)

    assert Visits.suggest(visits(), "  ", 8, @now) == []
  end

  test "title words match in any order and the limit applies" do
    assert [{"https://elixir-lang.org/", _}] =
             Visits.suggest(visits(), "language programming", 8, @now)

    assert length(Visits.suggest(visits(), "elixir", 2, @now)) == 2
  end

  test "frequent and recent visits rank higher among equals" do
    v =
      %{}
      |> Visits.record("https://a.test/one", "", @now - 1_000_000)
      |> Visits.record("https://a.test/two", "", @now - 10)
      |> Visits.record("https://a.test/two", "", @now - 5)

    assert [{"https://a.test/two", _} | _] = Visits.suggest(v, "a.test", 8, @now)
  end

  test "survives a round trip through a file, and a damaged file reads as empty" do
    dir = Path.join(System.tmp_dir!(), "visits_#{System.unique_integer([:positive])}")
    file = Path.join(dir, "history.etf")
    assert Visits.save(visits(), file) == :ok
    assert Visits.load(file) == visits()
    File.write!(file, "not a term")
    assert Visits.load(file) == %{}
    assert Visits.load(Path.join(dir, "missing")) == %{}
    File.rm_rf!(dir)
  end

  test "the oldest visits go when there are too many" do
    v = Enum.reduce(1..5_010, %{}, &Visits.record(&2, "https://h.test/#{&1}", "", @now + &1))
    assert map_size(v) == 5_000
    refute Map.has_key?(v, "https://h.test/1")
    assert Map.has_key?(v, "https://h.test/5010")
  end
end
