defmodule Browser.PublicSuffix do
  @moduledoc """
  The Public Suffix List (https://publicsuffix.org, MPL-2.0), shipped as
  `priv/public_suffix_list.dat`. Cookies use it to refuse `Domain` attributes that cover a
  whole registry (`co.uk`, `github.io`) and to tell which hosts are the same site.

  Both the ICANN and the private sections count, as in browsers. Rules with non-ASCII labels
  are skipped: hosts reach us as ASCII. The list is read on first use and kept in
  `:persistent_term`. To refresh it, download the file again from the URL above.
  """

  @key {__MODULE__, :rules}

  @doc "The public suffix of `host`: `\"co.uk\"` for `\"www.example.co.uk\"`."
  def suffix(host) do
    labels = host |> String.downcase() |> String.trim_trailing(".") |> String.split(".")
    %{rules: rules, wildcards: wildcards, exceptions: exceptions} = table()

    tails =
      for i <- 0..(length(labels) - 1)//1, do: Enum.drop(labels, i)

    Enum.find_value(tails, fn [_ | parent] = tail ->
      name = Enum.join(tail, ".")

      cond do
        name in exceptions -> Enum.join(parent, ".")
        name in rules -> name
        parent != [] and Enum.join(parent, ".") in wildcards -> name
        true -> nil
      end
    end) || List.last(labels)
  end

  @doc "Whether `host` is itself a public suffix (`\"co.uk\"`, `\"me.github.io\"` is not)."
  def public_suffix?(host), do: String.downcase(host) |> String.trim_trailing(".") == suffix(host)

  @doc """
  The registrable domain of `host`: its public suffix plus one label (`\"example.co.uk\"`).
  A host that is a public suffix, and one with no dot, is returned as is, as is an IP.
  """
  def registrable(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    if ip?(host) do
      host
    else
      suffix = suffix(host)
      labels = String.split(host, ".")
      n = length(String.split(suffix, "."))

      if length(labels) > n, do: labels |> Enum.take(-(n + 1)) |> Enum.join("."), else: host
    end
  end

  defp ip?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

  defp table do
    case :persistent_term.get(@key, nil) do
      nil ->
        table = load()
        :persistent_term.put(@key, table)
        table

      table ->
        table
    end
  end

  defp load do
    path = Application.app_dir(:browser, "priv/public_suffix_list.dat")

    path
    |> File.stream!()
    |> Stream.map(&(&1 |> String.split(~r/\s/, parts: 2) |> hd()))
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "//") or not ascii?(&1)))
    |> Enum.reduce(%{rules: MapSet.new(), wildcards: MapSet.new(), exceptions: MapSet.new()}, fn
      "!" <> rule, acc -> update_in(acc.exceptions, &MapSet.put(&1, rule))
      "*." <> rule, acc -> update_in(acc.wildcards, &MapSet.put(&1, rule))
      rule, acc -> update_in(acc.rules, &MapSet.put(&1, rule))
    end)
  end

  defp ascii?(str), do: String.match?(str, ~r/\A[\x00-\x7F]*\z/)
end
