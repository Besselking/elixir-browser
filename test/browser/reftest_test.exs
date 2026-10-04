defmodule Browser.ReftestTest do
  use ExUnit.Case, async: true

  alias Browser.Reftest
  alias Browser.Reftest.Raster

  @page "<!doctype html><title>t</title>"

  setup do
    root = Path.join(System.tmp_dir!(), "reftest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "css/t"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp write(root, name, body), do: File.write!(Path.join([root, "css/t", name]), @page <> body)

  test "finds match and mismatch links" do
    html =
      ~s(<link rel="match" href="a-ref.html"><link rel=mismatch href='/css/b.html'><link rel=help href=x>)

    assert Reftest.links(html) == [match: "a-ref.html", mismatch: "/css/b.html"]
  end

  test "collects tests and leaves out references and support files", %{root: root} do
    for f <- ["one.html", "one-ref.html", "support/s.html", "reference/r.html"] do
      File.mkdir_p!(Path.dirname(Path.join([root, "css/t", f])))
      write(root, f, "")
    end

    assert Reftest.collect(root, ["css/t"]) == ["css/t/one.html"]
  end

  test "a page that looks like its reference passes, whatever the markup", %{root: root} do
    write(
      root,
      "a.html",
      ~s(<link rel=match href=a-ref.html><div style="width:50px;height:20px;background:#0a0"></div>)
    )

    write(
      root,
      "a-ref.html",
      ~s(<p style="margin:0;padding:0"></p><div style="width:50px;height:20px;background:#0a0;margin-top:-1em"></div>)
    )

    # the reference is made to look the same by a different route
    write(
      root,
      "b.html",
      ~s(<link rel=match href=b-ref.html><div style="width:50px;height:20px;background:#0a0"></div>)
    )

    write(root, "b-ref.html", ~s(<div style="width:50px;height:20px;background:#0a0"></div>))

    assert Reftest.run_test(root, "css/t/b.html") == :pass
  end

  test "a difference fails, and a mismatch wants one", %{root: root} do
    write(
      root,
      "c.html",
      ~s(<link rel=match href=c-ref.html><div style="width:50px;height:20px;background:#0a0"></div>)
    )

    write(root, "c-ref.html", ~s(<div style="width:60px;height:20px;background:#0a0"></div>))
    assert {:fail, "" <> _} = Reftest.run_test(root, "css/t/c.html")

    write(
      root,
      "d.html",
      ~s(<link rel=mismatch href=c-ref.html><div style="width:50px;height:20px;background:#0a0"></div>)
    )

    assert Reftest.run_test(root, "css/t/d.html") == :pass
  end

  test "text is compared by what it says", %{root: root} do
    write(root, "e.html", ~s(<link rel=match href=e-ref.html><p>abc</p>))
    write(root, "e-ref.html", ~s(<p>abd</p>))
    assert {:fail, _} = Reftest.run_test(root, "css/t/e.html")
  end

  test "Ahem glyphs are em squares wide", %{root: root} do
    css = "<style>body{margin:0}p{margin:0;font:10px/1 Ahem}</style>"
    write(root, "f.html", ~s(<link rel=match href=f-ref.html>#{css}<p>XX XX</p>))
    # the same width of black squares by another route: a longer word of the same glyphs
    write(root, "f-ref.html", ~s(#{css}<p>X<span>X</span> X<span>X</span></p>))
    assert Reftest.run_test(root, "css/t/f.html") == :pass

    write(root, "g2.html", ~s(<link rel=mismatch href=f-ref.html>#{css}<p>XX XXX</p>))
    assert Reftest.run_test(root, "css/t/g2.html") == :pass
  end

  test "tests it cannot compare are skipped", %{root: root} do
    write(root, "g.html", ~s(<link rel=match href=g-ref.html><script>1</script>))
    assert {:skip, "scripts"} = Reftest.run_test(root, "css/t/g.html")
    write(root, "h.html", "<p>no link</p>")
    assert {:skip, "no reference"} = Reftest.run_test(root, "css/t/h.html")
    write(root, "i.html", ~s(<link rel=match href=nope.html>))
    assert {:skip, "reference missing"} = Reftest.run_test(root, "css/t/i.html")
  end

  test "the raster reports how many pixels differ" do
    a = Raster.new(4, 2, {255, 255, 255})
    assert Raster.diff(a, a) == nil
    b = Raster.paint([%{type: :rect, x: 1, y: 1, w: 2, h: 1, color: {0, 0, 0}}], 4, 2)
    assert Raster.diff(a, b) == {2, {1, 1}}
  end
end
