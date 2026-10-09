defmodule Browser.NetworkWindow do
  @moduledoc """
  The network panel: a window of its own that lists the requests of `Browser.NetLog`
  (status, method, type, size, time, address) with the headers of the one selected below,
  a Clear button and a filter for the address.

  The window is made when it is first opened and then only hidden. `Browser.Session` owns it:
  the clear button, the filter and the list send their wx events to the process that opened it.
  """

  @clear_id 5220
  @filter_id 5221
  @list_id 5222

  @horizontal 4
  @vertical 8
  @all 240
  @expand 8192
  @teletype 76
  @normal 90
  # report view, one row selected at a time
  @lc_report 32 + 8192
  # multi-line, read-only
  @te_details 32 + 16 + 32768

  defstruct [:frame, :list, :details, :filter, :count]

  def clear_id, do: @clear_id
  def filter_id, do: @filter_id
  def list_id, do: @list_id

  @doc "The menu text and shortcut that open the panel (Cmd+Option+E on a Mac, else Ctrl+Shift+E)."
  def menu_label do
    case :os.type() do
      {:unix, :darwin} -> ~c"Network\tCtrl+Alt+E"
      _ -> ~c"Network\tCtrl+Shift+E"
    end
  end

  @doc "Builds the window, hidden. The calling process gets its events."
  def new(parent) do
    frame = :wxFrame.new(parent, -1, ~c"Network", size: {900, 520})
    panel = :wxPanel.new(frame)

    clear = :wxButton.new(panel, @clear_id, label: ~c"Clear")
    label = :wxStaticText.new(panel, -1, ~c"Filter")
    filter = :wxTextCtrl.new(panel, @filter_id)
    count = :wxStaticText.new(panel, -1, ~c"", size: {110, -1})

    list = :wxListCtrl.new(panel, winid: @list_id, style: @lc_report)

    for {{title, width}, col} <- Enum.with_index(columns()),
        do: add_column(list, col, title, width)

    details = :wxTextCtrl.new(panel, -1, style: @te_details)
    :wxWindow.setBackgroundColour(details, {255, 255, 255})
    :wxWindow.setFont(details, :wxFont.new(12, @teletype, @normal, @normal))

    top = :wxBoxSizer.new(@horizontal)
    :wxSizer.add(top, clear, border: 4, flag: @all)
    :wxSizer.add(top, count, border: 4, flag: @all)
    :wxSizer.add(top, label, border: 4, flag: @all)
    :wxSizer.add(top, filter, proportion: 1, border: 4, flag: @all)
    col = :wxBoxSizer.new(@vertical)
    :wxSizer.add(col, top, flag: @expand)
    :wxSizer.add(col, list, proportion: 3, flag: @expand)
    :wxSizer.add(col, details, proportion: 2, flag: @expand)
    :wxWindow.setSizer(panel, col)

    :wxButton.connect(clear, :command_button_clicked)
    :wxTextCtrl.connect(filter, :command_text_updated)
    :wxListCtrl.connect(list, :command_list_item_selected)

    # closing the window only hides it
    :wxFrame.connect(frame, :close_window, callback: fn _event, _obj -> :wxWindow.hide(frame) end)

    %__MODULE__{frame: frame, list: list, details: details, filter: filter, count: count}
  end

  defp add_column(list, col, title, width) do
    :wxListCtrl.insertColumn(list, col, String.to_charlist(title))
    :wxListCtrl.setColumnWidth(list, col, width)
  end

  defp columns,
    do: [{"Status", 110}, {"Method", 70}, {"Type", 80}, {"Size", 80}, {"Time", 80}, {"URL", 1000}]

  def show(%{frame: frame}) do
    :wxWindow.show(frame)
    :wxWindow.raise(frame)
  end

  def shown?(%{frame: frame}), do: :wxWindow.isShown(frame)

  @doc "The text in the filter box."
  def filter_text(%{filter: filter}), do: :wxTextCtrl.getValue(filter) |> to_string()

  @doc "Empties the list and the details."
  def clear(%{list: list, details: details, count: count}) do
    :wxListCtrl.deleteAllItems(list)
    :wxTextCtrl.setValue(details, ~c"")
    :wxStaticText.setLabel(count, ~c"")
  end

  @doc "Adds entries (`Browser.NetLog` maps) to the end of the list."
  def append(_win, []), do: :ok

  def append(%{list: list, count: count}, entries) do
    for entry <- entries do
      i = :wxListCtrl.getItemCount(list)
      :wxListCtrl.insertItem(list, i, String.to_charlist(hd(row(entry))))

      for {text, col} <- Enum.with_index(tl(row(entry)), 1),
          do: :wxListCtrl.setItem(list, i, col, String.to_charlist(text))
    end

    :wxListCtrl.ensureVisible(list, :wxListCtrl.getItemCount(list) - 1)

    :wxStaticText.setLabel(
      count,
      String.to_charlist("#{:wxListCtrl.getItemCount(list)} requests")
    )
  end

  @doc "Shows the details of one entry (nil: none)."
  def show_details(%{details: details}, entry),
    do:
      :wxTextCtrl.setValue(
        details,
        String.to_charlist(if(entry, do: details_text(entry), else: ""))
      )

  @doc "The cells of an entry's row: status, method, type, size, time, address."
  def row(entry) do
    [
      status_text(entry),
      entry.method,
      entry.type,
      if(entry.source == :cache, do: "(cache)", else: size_text(entry.size)),
      if(entry.source == :cache, do: "", else: "#{entry.ms} ms"),
      entry.url
    ]
  end

  defp status_text(%{status: nil}), do: "(failed)"
  defp status_text(%{status: s, source: :cache}), do: "#{s} (cache)"
  defp status_text(%{status: 304}), do: "304 (cached)"
  defp status_text(%{status: s}), do: Integer.to_string(s)

  @doc "`512 B`, `4.5 KB`, `1.2 MB`."
  def size_text(n) when n < 1024, do: "#{n} B"
  def size_text(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def size_text(n), do: "#{Float.round(n / 1024 / 1024, 1)} MB"

  @doc "The text of the details area: the request, then its headers."
  def details_text(entry) do
    [
      "#{entry.method} #{entry.url}",
      status_line(entry),
      "Type: #{entry.type}    Size: #{size_text(entry.size)}    Time: #{entry.ms} ms",
      "Initiator: #{entry.initiator || "(address bar)"}",
      "",
      "Request headers",
      headers_text(entry.request_headers, "(none sent: the response came from the cache)"),
      "",
      "Response headers",
      headers_text(entry.response_headers, "(none)")
    ]
    |> Enum.join("\n")
  end

  defp status_line(%{source: :error, error: error}), do: "Failed: #{error}"

  defp status_line(%{status: status, status_text: text, source: source}) do
    from =
      case source do
        :cache -> "from the cache"
        :revalidated -> "the cached copy is still good"
        _ -> "from the network"
      end

    "Status: #{status} #{text} (#{from})"
  end

  defp headers_text([], none), do: "  " <> none
  defp headers_text(headers, _), do: Enum.map_join(headers, "\n", fn {k, v} -> "  #{k}: #{v}" end)

  @doc "Does `entry` pass the filter text (part of its address, any case)?"
  def match?(entry, ""), do: entry != nil
  def match?(entry, text), do: String.contains?(String.downcase(entry.url), String.downcase(text))
end
