defmodule Browser.PublicSuffixTest do
  use ExUnit.Case, async: true
  alias Browser.PublicSuffix

  test "suffix" do
    assert PublicSuffix.suffix("www.example.com") == "com"
    assert PublicSuffix.suffix("www.example.co.uk") == "co.uk"
    assert PublicSuffix.suffix("me.github.io") == "github.io"
    # unlisted TLDs count as a suffix of one label
    assert PublicSuffix.suffix("a.b.unlisted-tld") == "unlisted-tld"
  end

  test "wildcard and exception rules" do
    # *.ck is a rule, !www.ck an exception to it
    assert PublicSuffix.suffix("a.b.ck") == "b.ck"
    assert PublicSuffix.suffix("www.ck") == "ck"
    assert PublicSuffix.registrable("www.ck") == "www.ck"
    assert PublicSuffix.registrable("x.www.ck") == "www.ck"
  end

  test "registrable" do
    assert PublicSuffix.registrable("a.b.example.com") == "example.com"
    assert PublicSuffix.registrable("a.example.co.uk") == "example.co.uk"
    assert PublicSuffix.registrable("co.uk") == "co.uk"
    assert PublicSuffix.registrable("localhost") == "localhost"
    assert PublicSuffix.registrable("127.0.0.1") == "127.0.0.1"
    assert PublicSuffix.registrable("EXAMPLE.com.") == "example.com"
  end

  test "public_suffix?" do
    assert PublicSuffix.public_suffix?("com")
    assert PublicSuffix.public_suffix?("co.uk")
    assert PublicSuffix.public_suffix?("github.io")
    refute PublicSuffix.public_suffix?("example.com")
  end
end
