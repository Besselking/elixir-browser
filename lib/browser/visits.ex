defmodule Browser.Visits do
  @moduledoc """
  The pages that have been visited, kept between runs, and suggestions for the address bar
  drawn from them. Pure apart from `load/1` and `save/2`.

  A visit is `%{title:, count:, last:}` by address; `last` is a Unix time in seconds.
  """

  @max 5_000
  @half_life 14 * 86_400

  @doc "Where the history lives; `nil` (config `:history_path`) keeps it in memory only."
  def path do
    case Application.fetch_env(:browser, :history_path) do
      {:ok, path} ->
        path

      :error ->
        Path.join(:filename.basedir(:user_data, ~c"elixir_browser") |> to_string(), "history.etf")
    end
  end

  def load(path \\ path())

  def load(nil), do: %{}

  def load(path) do
    with {:ok, bin} <- File.read(path),
         visits when is_map(visits) <- safe_decode(bin) do
      visits
    else
      _ -> %{}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> nil
  end

  @doc "Writes `visits`, through a temporary file so a crash can't leave half a history."
  def save(visits, path \\ path())

  def save(_visits, nil), do: :ok

  def save(visits, path) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, :erlang.term_to_binary(visits))
    File.rename!(tmp, path)
    :ok
  rescue
    _ -> :error
  end

  @doc "Notes a visit to `url` at `now`. Only web addresses are remembered."
  def record(visits, url, title, now \\ System.os_time(:second)) do
    if remembered?(url) do
      title = title |> to_string() |> String.trim()

      visits =
        Map.update(
          visits,
          url,
          %{title: title, count: 1, last: now},
          &%{
            &1
            | title: if(title == "", do: &1.title, else: title),
              count: &1.count + 1,
              last: now
          }
        )

      trim(visits)
    else
      visits
    end
  end

  defp remembered?(url), do: is_binary(url) and String.match?(url, ~r{\Ahttps?://}i)

  defp trim(visits) when map_size(visits) <= @max, do: visits

  defp trim(visits) do
    visits
    |> Enum.sort_by(fn {_, v} -> v.last end, :desc)
    |> Enum.take(@max)
    |> Map.new()
  end

  @doc "Forgets everything."
  def clear, do: %{}

  @doc """
  Up to `limit` visits that match what was typed, best first: `[{url, title}]`. An address that
  starts with the text (scheme and `www.` aside) beats one that contains it, and that beats a
  title that does; within those, often and recently visited pages come first.
  """
  def suggest(visits, query, limit \\ 8, now \\ System.os_time(:second)) do
    q = query |> to_string() |> String.trim() |> String.downcase()

    if q == "" do
      []
    else
      q = strip(q)

      visits
      |> Enum.flat_map(fn {url, v} ->
        case rank(url, v.title, q) do
          nil -> []
          r -> [{{r, frecency(v, now)}, url, v.title}]
        end
      end)
      |> Enum.sort_by(fn {score, url, _} -> {score, url} end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_, url, title} -> {url, title} end)
    end
  end

  defp rank(url, title, q) do
    plain = url |> String.downcase() |> strip()
    host = plain |> String.split("/", parts: 2) |> hd()

    cond do
      String.starts_with?(plain, q) -> 4
      String.starts_with?(host, q) -> 4
      String.contains?(host, q) -> 3
      String.contains?(plain, q) -> 2
      words_match?(String.downcase(title || ""), q) -> 1
      true -> nil
    end
  end

  # every word typed is somewhere in the title
  defp words_match?("", _), do: false

  defp words_match?(title, q),
    do: q |> String.split() |> Enum.all?(&String.contains?(title, &1))

  defp strip(s), do: s |> String.replace(~r{\Ahttps?://}, "") |> String.replace(~r{\Awww\.}, "")

  defp frecency(%{count: n, last: last}, now) do
    age = max(now - last, 0)
    :math.log(n + 1) * :math.pow(0.5, age / @half_life)
  end
end
