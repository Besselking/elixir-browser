defmodule Browser.Download do
  @moduledoc """
  Saves what a link with a `download` attribute points to in the Downloads folder.

  The folder is `Path.join(System.user_home!(), "Downloads")`, or the `:downloads_dir` of the
  `:browser` application when it is set (the tests give a temporary folder). The bytes come
  from the page (a `blob:` URL, see `Browser.JS.DOM`) or from a fetch (`data:`, `http(s):`).
  A file that is there already is never written over: the new one gets " (1)", " (2)", ...
  """

  alias Browser.Fetch

  @fallback "download"

  @doc "The folder the downloads go to."
  def dir do
    Application.get_env(:browser, :downloads_dir) || Path.join(System.user_home!(), "Downloads")
  end

  @doc """
  Saves the resource at `url` as `name` (the `download` attribute) in `dir/0`, which is made
  when it is not there. `data` is the content when the page has it (a blob), else nil and
  `fetch` (`fn url -> {:ok, body, final} | {:error, msg} end`) gets it. Returns
  `{:ok, path}` or `{:error, message}`.
  """
  def save(url, name, data, fetch \\ &Fetch.load/1) do
    dir = dir()

    with {:ok, bytes} <- content(url, data, fetch),
         :ok <- mkdir(dir) do
      write_new(dir, file_name(name, url), bytes, 0)
    end
  end

  defp content(_url, data, _fetch) when is_binary(data), do: {:ok, data}
  defp content("blob:" <> _, nil, _fetch), do: {:error, "the blob is not there any more"}

  defp content(url, nil, fetch) do
    case fetch.(url) do
      {:ok, body, _final} when is_binary(body) -> {:ok, body}
      {:error, msg} -> {:error, to_string(msg)}
      _ -> {:error, "no content"}
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot make #{dir}: #{:file.format_error(reason)}"}
    end
  end

  # (`:exclusive` fails when the file is there, also when another download made it just now)
  defp write_new(dir, name, bytes, n) do
    path = Path.join(dir, numbered(name, n))

    case File.write(path, bytes, [:exclusive]) do
      :ok -> {:ok, path}
      {:error, :eexist} -> write_new(dir, name, bytes, n + 1)
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  The name of the `n`-th file with `name`: the name itself for 0, else `"report (2).json"`
  for `"report.json"` and 2.
  """
  def numbered(name, 0), do: name

  def numbered(name, n) do
    ext = Path.extname(name)
    # (a name that is only an extension, such as "x." or ".json" after the dots went, has none)
    if ext in ["", "."] or ext == name,
      do: "#{name} (#{n})",
      else: "#{binary_part(name, 0, byte_size(name) - byte_size(ext))} (#{n})#{ext}"
  end

  @doc """
  A safe file name for the `download` attribute `attr` of a link to `url`: path separators,
  `:` and control characters become `_`, leading dots and spaces go. An empty name takes the
  last part of the URL's path, or "download".
  """
  def file_name(attr, url) do
    case clean(attr || "") do
      "" ->
        case clean(url_name(url)) do
          "" -> @fallback
          name -> name
        end

      name ->
        name
    end
  end

  defp clean(name) do
    name
    |> String.replace(~r/[\/\\:\x00-\x1f\x7f]/, "_")
    |> String.trim()
    |> String.trim_leading(".")
    |> String.trim()
  end

  # (a `blob:` or `data:` URL has no name in it)
  defp url_name(url) do
    case URI.parse(url || "") do
      %URI{scheme: scheme, path: path}
      when scheme in ["http", "https", "file"] and is_binary(path) ->
        path |> String.split("/") |> List.last() |> decode()

      _ ->
        ""
    end
  end

  defp decode(s) do
    URI.decode(s)
  rescue
    ArgumentError -> s
  end
end
