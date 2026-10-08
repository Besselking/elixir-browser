defmodule Browser.Proxy do
  @moduledoc """
  HTTP proxy settings and TLS trust for the network layer.

  The proxy comes from the usual environment variables: `https_proxy` and `http_proxy`
  (the upper-case names are the fallback) and `no_proxy`. An HTTPS page goes through the
  proxy with a CONNECT tunnel, a plain HTTP page with an absolute-form request. A
  `user:pass@` part in the proxy URL is sent as `Proxy-Authorization`.

  `no_proxy` is a comma-separated list. An entry is `*`, a host name (it also matches the
  sub-domains, and a leading `.` or `*.` is allowed), an IP address, or a CIDR range.

  Requests that use a proxy go through a second `:httpc` profile, so the `no_proxy` rules
  can be done here and not by `:httpc`, which knows no CIDR ranges.

  TLS stays on `:verify_peer`. The trusted roots are the system store plus the PEM file
  named by `SSL_CERT_FILE`, if it is set, for example the CA of a proxy that re-signs TLS.
  """

  import Bitwise

  @profile :proxied

  def profile, do: @profile

  @doc "Start the proxy profile when the environment asks for a proxy. Call once at boot."
  def setup do
    config = from_env()
    :persistent_term.put({__MODULE__, :config}, config)
    :persistent_term.put({__MODULE__, :cacerts}, load_cacerts(System.get_env("SSL_CERT_FILE")))

    if config.http || config.https do
      {:ok, _} = :inets.start(:httpc, profile: @profile)

      :httpc.set_options(
        [max_sessions: 8, max_keep_alive_length: 20] ++
          proxy_option(:proxy, config.http) ++ proxy_option(:https_proxy, config.https),
        @profile
      )
    end

    :ok
  end

  @doc "The trusted CA certificates for TLS."
  def cacerts do
    :persistent_term.get({__MODULE__, :cacerts}, nil) || :public_key.cacerts_get()
  end

  @doc """
  How to send a request for `url`: `{profile, extra_http_options}`. The profile is `:default`
  for a direct request.
  """
  def route(url) do
    config = :persistent_term.get({__MODULE__, :config}, nil) || empty()

    with %URI{scheme: scheme, host: host} when is_binary(host) <- URI.parse(url),
         {_, _, auth} = proxy when proxy != nil <- proxy_for(config, scheme),
         false <- bypass?(config.no_proxy, host) do
      {@profile, if(auth, do: [proxy_auth: auth], else: [])}
    else
      _ -> {:default, []}
    end
  end

  @doc false
  def from_env(env \\ &System.get_env/1) do
    %{
      http: env_proxy(env, ["http_proxy", "HTTP_PROXY"]),
      https: env_proxy(env, ["https_proxy", "HTTPS_PROXY"]),
      no_proxy: parse_no_proxy(first_set(env, ["no_proxy", "NO_PROXY"]) || "")
    }
  end

  @doc false
  def bypass?(rules, host) do
    host = host |> String.downcase() |> String.trim_leading("[") |> String.trim_trailing("]")
    ip = parse_ip(host)
    Enum.any?(rules, &rule_matches?(&1, host, ip))
  end

  @doc false
  def parse_no_proxy(text) do
    for entry <- String.split(text, ","),
        entry = entry |> String.trim() |> String.downcase(),
        entry != "",
        do: parse_rule(entry)
  end

  @doc false
  def load_cacerts(nil), do: nil
  def load_cacerts(""), do: nil

  def load_cacerts(path) do
    with {:ok, pem} <- File.read(path),
         [_ | _] = entries <- :public_key.pem_decode(pem) do
      extra = for {:Certificate, der, :not_encrypted} <- entries, do: der
      Enum.uniq(extra ++ :public_key.cacerts_get())
    else
      _ -> nil
    end
  end

  defp empty, do: %{http: nil, https: nil, no_proxy: []}

  defp proxy_for(config, "https"), do: config.https
  defp proxy_for(config, "http"), do: config.http
  defp proxy_for(_config, _scheme), do: nil

  defp proxy_option(_key, nil), do: []

  defp proxy_option(key, {host, port, _auth}),
    do: [{key, {{String.to_charlist(host), port}, []}}]

  defp first_set(env, names) do
    Enum.find_value(names, fn name ->
      case env.(name) do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  defp env_proxy(env, names) do
    case first_set(env, names) do
      nil -> nil
      value -> parse_proxy_url(value)
    end
  end

  defp parse_proxy_url(value) do
    value = if String.contains?(value, "://"), do: value, else: "http://" <> value

    case URI.parse(value) do
      %URI{host: host, port: port, userinfo: info} when is_binary(host) and host != "" ->
        {host, port || 80, parse_auth(info)}

      _ ->
        nil
    end
  end

  defp parse_auth(nil), do: nil

  defp parse_auth(info) do
    {user, pass} =
      case String.split(info, ":", parts: 2) do
        [user, pass] -> {user, pass}
        [user] -> {user, ""}
      end

    {user |> URI.decode() |> String.to_charlist(), pass |> URI.decode() |> String.to_charlist()}
  end

  defp parse_rule("*"), do: :all

  defp parse_rule(entry) do
    entry = entry |> strip_port() |> String.trim_leading("*") |> String.trim_leading(".")

    case String.split(entry, "/", parts: 2) do
      [addr, bits] ->
        with {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)),
             {n, ""} <- Integer.parse(bits) do
          {:cidr, ip, n}
        else
          _ -> {:host, entry}
        end

      [addr] ->
        case parse_ip(addr) do
          nil -> {:host, addr}
          ip -> {:ip, ip}
        end
    end
  end

  # `host:port` but not a bare IPv6 address
  defp strip_port(entry) do
    case Regex.run(~r/^([^:\[\]\/]+):\d+$/, entry) do
      [_, host] -> host
      _ -> entry
    end
  end

  defp parse_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp rule_matches?(:all, _host, _ip), do: true
  defp rule_matches?({:ip, ip}, _host, ip), do: true
  defp rule_matches?({:cidr, net, bits}, _host, ip) when ip != nil, do: in_cidr?(ip, net, bits)

  defp rule_matches?({:host, name}, host, ip),
    do: ip == nil and (host == name or String.ends_with?(host, "." <> name))

  defp rule_matches?(_rule, _host, _ip), do: false

  defp in_cidr?(ip, net, bits) when tuple_size(ip) == tuple_size(net) do
    width = if tuple_size(ip) == 4, do: 32, else: 128
    bits = min(bits, width)
    shift = width - bits
    to_int(ip) >>> shift == to_int(net) >>> shift
  end

  defp in_cidr?(_ip, _net, _bits), do: false

  defp to_int(ip) do
    size = if tuple_size(ip) == 4, do: 8, else: 16

    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< size) + part end)
  end
end
