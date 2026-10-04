defmodule Browser.CookiesTest do
  use ExUnit.Case, async: false
  alias Browser.Cookies

  setup do
    Cookies.clear()
    :ok
  end

  test "a cookie comes back on the same host and path" do
    Cookies.store("http://a.test/x/y", ["id=1"])
    assert Cookies.header("http://a.test/x/z") == "id=1"
    # the default path is the directory of the request
    assert Cookies.header("http://a.test/other") == nil
    assert Cookies.header("http://b.test/x/y") == nil
  end

  test "Domain widens a cookie to subdomains, a host-only cookie stays put" do
    Cookies.store("http://www.a.test/", ["wide=1; Domain=a.test", "narrow=2"])
    assert Cookies.header("http://sub.a.test/") == "wide=1"
    assert Cookies.header("http://www.a.test/") == "wide=1; narrow=2"
    assert Cookies.header("http://a.test/") == "wide=1"
  end

  test "a Domain the host is not in, or a bare TLD, is refused" do
    Cookies.store("http://a.test/", ["x=1; Domain=b.test", "y=1; Domain=test"])
    assert Cookies.all() == []
  end

  test "Path limits where a cookie goes, on segment boundaries" do
    Cookies.store("http://a.test/", ["p=1; Path=/app"])
    assert Cookies.header("http://a.test/app") == "p=1"
    assert Cookies.header("http://a.test/app/x") == "p=1"
    assert Cookies.header("http://a.test/apple") == nil
  end

  test "Secure cookies are only sent over https and only set from https" do
    Cookies.store("http://a.test/", ["s=1; Secure"])
    assert Cookies.all() == []
    Cookies.store("https://a.test/", ["s=1; Secure"])
    assert Cookies.header("https://a.test/") == "s=1"
    assert Cookies.header("http://a.test/") == nil
  end

  test "Max-Age and Expires expire and delete cookies" do
    Cookies.store("http://a.test/", [
      "a=1; Max-Age=3600",
      "b=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT"
    ])

    assert Cookies.header("http://a.test/") == "a=1; b=1"

    Cookies.store("http://a.test/", [
      "a=1; Max-Age=0",
      "b=1; Expires=Thu, 01 Jan 1970 00:00:01 GMT"
    ])

    assert Cookies.header("http://a.test/") == nil
  end

  test "Max-Age wins over Expires" do
    Cookies.store("http://a.test/", ["a=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Max-Age=0"])
    assert Cookies.all() == []
  end

  test "date parsing is lenient" do
    assert Cookies.parse_date("Sun, 06 Nov 1994 08:49:37 GMT") == 784_111_777
    assert Cookies.parse_date("Sunday, 06-Nov-94 08:49:37 GMT") == 784_111_777
    assert Cookies.parse_date("Sun Nov  6 08:49:37 1994") == 784_111_777
    assert Cookies.parse_date("nonsense") == nil
  end

  test "a later cookie replaces one with the same name, domain and path" do
    Cookies.store("http://a.test/", ["a=1"])
    Cookies.store("http://a.test/", ["a=2"])
    assert Cookies.header("http://a.test/") == "a=2"
  end

  test "longer paths come first" do
    Cookies.store("http://a.test/", ["a=root", "b=deep; Path=/x/y"])
    assert Cookies.header("http://a.test/x/y/z") == "b=deep; a=root"
  end

  test "HttpOnly cookies are kept from scripts" do
    Cookies.store("http://a.test/", ["h=1; HttpOnly", "v=2"])
    assert Cookies.header("http://a.test/") == "h=1; v=2"
    assert Cookies.header("http://a.test/", http: false) == "v=2"
    Cookies.set_from_script("http://a.test/", "h=9; HttpOnly")
    assert Cookies.header("http://a.test/") == "h=1; v=2"
  end

  test "junk is ignored" do
    Cookies.store("http://a.test/", ["", "   ", ";;;"])
    assert Cookies.all() == []
    Cookies.store("file:///etc/passwd", ["a=1"])
    assert Cookies.all() == []
  end

  test "the jar is bounded per domain" do
    for i <- 1..60, do: Cookies.store("http://a.test/", ["c#{i}=1"])
    assert length(Cookies.all()) == 50
  end

  describe "SameSite" do
    @cross [cross_site: true]

    test "same-site requests get every cookie" do
      Cookies.store("https://a.test/", ["s=1; SameSite=Strict", "l=2; SameSite=Lax", "u=3"])
      assert Cookies.header("https://a.test/", cross_site: false) == "s=1; l=2; u=3"
    end

    test "cross-site subresource requests get only SameSite=None" do
      Cookies.store("https://a.test/", [
        "s=1; SameSite=Strict",
        "l=2",
        "n=3; SameSite=None; Secure"
      ])

      assert Cookies.header("https://a.test/x", @cross) == "n=3"
    end

    test "Lax (also the default) travels on cross-site top-level GET navigations only" do
      Cookies.store("https://a.test/", ["s=1; SameSite=Strict", "l=2; SameSite=Lax", "d=3"])
      nav = [cross_site: true, navigation: true]
      assert Cookies.header("https://a.test/", nav) == "l=2; d=3"
      assert Cookies.header("https://a.test/", nav ++ [method: :post]) == nil
    end

    test "SameSite=None needs Secure" do
      Cookies.store("https://a.test/", ["n=1; SameSite=None"])
      assert Cookies.all() == []
    end

    test "a cross-site response sets only None cookies, and Lax ones on a navigation" do
      Cookies.store(
        "https://a.test/",
        ["s=1; SameSite=Strict", "l=2", "n=3; SameSite=None; Secure"],
        @cross
      )

      assert Enum.map(Cookies.all(), & &1.name) == ["n"]

      Cookies.store("https://a.test/", ["s=1; SameSite=Strict", "l=2"],
        cross_site: true,
        navigation: true
      )

      assert Enum.sort(Enum.map(Cookies.all(), & &1.name)) == ["l", "n"]
    end

    test "same_site? compares scheme and registrable domain" do
      assert Cookies.same_site?("https://www.a.test/x", "https://api.a.test/y")
      refute Cookies.same_site?("https://a.test/", "https://b.test/")
      refute Cookies.same_site?("http://a.test/", "https://a.test/")
      refute Cookies.same_site?("https://a.co.uk/", "https://b.co.uk/")
      assert Cookies.same_site?("https://x.a.co.uk/", "https://y.a.co.uk/")
      refute Cookies.same_site?("https://me.github.io/", "https://you.github.io/")
      assert Cookies.same_site?("http://127.0.0.1:1/", "http://127.0.0.1:2/")
      refute Cookies.same_site?("http://127.0.0.1/", "http://127.0.0.2/")
    end
  end

  describe "other checks" do
    test "__Secure- and __Host- prefixes" do
      Cookies.store("https://a.test/", [
        "__Secure-a=1",
        "__Secure-b=1; Secure",
        "__Host-c=1; Secure; Path=/",
        "__Host-d=1; Secure; Path=/; Domain=a.test",
        "__Host-e=1; Secure; Path=/x",
        "__host-f=1"
      ])

      assert Cookies.all() |> Enum.map(& &1.name) |> Enum.sort() == ["__Host-c", "__Secure-b"]
    end

    test "public suffixes and IPs cannot be Domain" do
      Cookies.store("https://a.co.uk/", ["x=1; Domain=co.uk"])
      Cookies.store("https://me.github.io/", ["y=1; Domain=github.io"])
      Cookies.store("http://127.0.0.1/", ["z=1; Domain=0.0.1"])
      assert Cookies.all() == []
      Cookies.store("https://shop.a.co.uk/", ["ok=1; Domain=a.co.uk"])
      assert Cookies.header("https://www.a.co.uk/") == "ok=1"
    end

    test "an insecure page cannot overwrite a Secure cookie" do
      Cookies.store("https://a.test/", ["id=good; Secure"])
      Cookies.store("http://a.test/", ["id=evil"])
      assert Cookies.header("https://a.test/") == "id=good"
    end

    test "size limits, control characters and lifetime" do
      Cookies.store("http://a.test/", [
        "big=" <> String.duplicate("x", 4100),
        "ctl=a\x01b",
        "p=1; Path=/" <> String.duplicate("x", 1100)
      ])

      assert Cookies.all() == []
      Cookies.store("http://a.test/", ["long=1; Max-Age=999999999"])
      [c] = Cookies.all()
      assert c.expires_at <= System.os_time(:second) + 400 * 86_400
    end
  end
end
