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
end
