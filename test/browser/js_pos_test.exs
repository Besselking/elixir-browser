defmodule Browser.JS.PosTest do
  # The position of a statement as one integer (`Browser.JS.Pos`).
  use ExUnit.Case, async: true

  alias Browser.JS
  alias Browser.JS.Pos

  test "a position gives back its file and its line" do
    for {file, line} <- [{"t.js", 1}, {"t.js", 0}, {"inline script 3", 4096}, {"b.js", 9}] do
      pos = Pos.encode(file, line)
      assert is_integer(pos)
      assert Pos.decode(pos) == {file, line}
    end

    assert Pos.decode(nil) == nil
    assert Pos.decode(:undefined) == nil
  end

  test "a file keeps its number, also in another process" do
    id = Pos.file_id("same.js")
    assert Pos.file_id("same.js") == id
    assert Task.await(Task.async(fn -> Pos.file_id("same.js") end)) == id
  end

  # (the two names have the same hash: `:erlang.phash2(name, 1 <<< 31)` is 1467461442)
  test "two files with the same hash get two numbers" do
    a = Pos.encode("f22877.js", 5)
    b = Pos.encode("f75067.js", 6)
    assert a != b
    assert Pos.decode(a) == {"f22877.js", 5}
    assert Pos.decode(b) == {"f75067.js", 6}
  end

  # (`JS.eval/2` parses in the process that calls it and runs the script in a new process)
  test "a parse in one process runs in another with the same stack text" do
    src = "function f(){\n  return new Error('x').stack\n}\nf()"
    {:ok, text, _} = JS.eval(src, file: "moved.js")
    assert text == "Error: x\n    at f (moved.js:2)\n    at moved.js:4"
  end
end
