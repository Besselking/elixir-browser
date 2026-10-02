defmodule Browser.Prefetch do
  @moduledoc """
  Starts fetching a page's stylesheets while its HTML is still arriving.

  `feed/2` is given each piece of the document (it is meant as `Fetch.load`'s `on_chunk`),
  spots complete `<link rel=stylesheet>` tags and downloads their URLs in parallel.
  `take/2` later hands the result for a URL to the process that did the feeding, which
  keeps the state in its process dictionary.
  """

  alias Browser.{Fetch, HTML, Style}

  @key {__MODULE__, :state}
  @max_sheets 24
  @link ~r/<link\b[^>]*>/i

  @doc "Forgets earlier prefetches in this process."
  def reset, do: Process.put(@key, %{buf: "", started: MapSet.new()})

  @doc "Handles a piece of the document at `base`; `allowed?` says whether a sheet may be loaded."
  def feed(chunk, base, allowed?) do
    st = Process.get(@key) || reset_state()

    if MapSet.size(st.started) >= @max_sheets do
      :ok
    else
      buf = st.buf <> chunk
      links = Regex.scan(@link, buf)
      rest = rest_after(buf, links)
      st = %{st | buf: rest}

      started =
        Enum.reduce(links, st.started, fn [tag], started ->
          tag |> hrefs() |> Enum.reduce(started, &start(&1, &2, base, allowed?))
        end)

      Process.put(@key, %{st | started: started})
      :ok
    end
  end

  @doc """
  The prefetched `{:ok, css, final_url}` (or `{:error, _}`) for `url`, waiting for it if
  it is still downloading; `:none` when it was never started.
  """
  def take(url, timeout) do
    case Process.get(@key) do
      %{started: started} = st ->
        case st[:results][url] do
          nil -> await(st, started, url, timeout)
          result -> result
        end

      _ ->
        :none
    end
  end

  defp await(st, started, url, timeout) do
    if MapSet.member?(started, url) do
      receive do
        {__MODULE__, ^url, result} ->
          Process.put(@key, Map.update(st, :results, %{url => result}, &Map.put(&1, url, result)))
          result
      after
        timeout -> :none
      end
    else
      :none
    end
  end

  defp reset_state do
    reset()
    Process.get(@key)
  end

  # what follows the last complete tag, cut to a possibly unfinished tag at its end
  defp rest_after(buf, links) do
    tail =
      case List.last(links) do
        nil ->
          buf

        [tag] ->
          {pos, len} = :binary.match(buf, tag)
          binary_part(buf, pos + len, byte_size(buf) - pos - len)
      end

    case :binary.matches(tail, "<") do
      [] ->
        ""

      matches ->
        binary_part(
          tail,
          elem(List.last(matches), 0),
          byte_size(tail) - elem(List.last(matches), 0)
        )
    end
  end

  defp hrefs(tag) do
    for {:link, href} <- tag |> HTML.parse() |> Style.sheet_refs(), do: href
  end

  defp start(href, started, base, allowed?) do
    url = Fetch.resolve(base, href)

    if MapSet.member?(started, url) or not allowed?.(url) do
      started
    else
      me = self()
      spawn(fn -> send(me, {__MODULE__, url, Fetch.load(url)}) end)
      MapSet.put(started, url)
    end
  end
end
