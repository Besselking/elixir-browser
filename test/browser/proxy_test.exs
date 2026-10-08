defmodule Browser.ProxyTest do
  use ExUnit.Case, async: true

  alias Browser.Proxy

  defp env(map), do: fn name -> Map.get(map, name) end

  test "reads proxies and credentials from the environment" do
    config =
      Proxy.from_env(
        env(%{
          "https_proxy" => "http://us%40er:p%3Aw@127.0.0.1:8080",
          "HTTP_PROXY" => "proxy.local"
        })
      )

    assert config.https == {"127.0.0.1", 8080, {~c"us@er", ~c"p:w"}}
    assert config.http == {"proxy.local", 80, nil}
  end

  test "lower-case names win over upper-case ones" do
    config = Proxy.from_env(env(%{"https_proxy" => "http://a:1", "HTTPS_PROXY" => "http://b:2"}))
    assert {"a", 1, nil} = config.https
  end

  test "no proxy without variables" do
    assert %{http: nil, https: nil, no_proxy: []} = Proxy.from_env(env(%{}))
  end

  test "no_proxy matching" do
    rules =
      Proxy.parse_no_proxy("localhost, .example.com,*.corp.net,10.0.0.0/8,192.168.1.5,fe80::/10")

    assert Proxy.bypass?(rules, "localhost")
    assert Proxy.bypass?(rules, "example.com")
    assert Proxy.bypass?(rules, "www.example.com")
    assert Proxy.bypass?(rules, "a.corp.net")
    assert Proxy.bypass?(rules, "10.1.2.3")
    assert Proxy.bypass?(rules, "192.168.1.5")
    assert Proxy.bypass?(rules, "[fe80::1]")
    refute Proxy.bypass?(rules, "notexample.com")
    refute Proxy.bypass?(rules, "11.0.0.1")
    refute Proxy.bypass?(rules, "192.168.1.6")
    refute Proxy.bypass?(rules, "github.com")
  end

  test "a star bypasses everything" do
    assert Proxy.bypass?(Proxy.parse_no_proxy("*"), "github.com")
  end

  test "an extra CA file is added to the system roots" do
    assert Proxy.load_cacerts(nil) == nil
    assert Proxy.load_cacerts("/nonexistent") == nil

    path = "/root/.ccr/ca-bundle.crt"

    if File.exists?(path) do
      assert length(Proxy.load_cacerts(path)) >= length(:public_key.cacerts_get())
    end
  end
end
