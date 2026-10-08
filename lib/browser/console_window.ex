defmodule Browser.ConsoleWindow do
  @moduledoc """
  The developer console: a window of its own that shows the console log of the current tab
  (`Browser.Console`) and has a line to evaluate JavaScript in the page.

  The window is made when it is first opened and then only hidden. `Browser.Session` owns it:
  the clear button and the input line send their wx events to the process that opened it.
  """

  @clear_id 5210
  @input_id 5211

  @te_process_enter 1024
  # multi-line, read-only, styled text
  @te_log 32 + 16 + 32768
  @horizontal 4
  @vertical 8
  @all 240
  @expand 8192
  @teletype 76
  @normal 90

  defstruct [:frame, :log, :input, :clear]

  def clear_id, do: @clear_id
  def input_id, do: @input_id

  @doc "The menu text and shortcut that open the console (Cmd+Option+J on a Mac, else Ctrl+Shift+J)."
  def menu_label do
    case :os.type() do
      {:unix, :darwin} -> ~c"Developer Console\tCtrl+Alt+J"
      _ -> ~c"Developer Console\tCtrl+Shift+J"
    end
  end

  @doc "Builds the window, hidden. The calling process gets its events."
  def new(parent) do
    frame = :wxFrame.new(parent, -1, ~c"Console", size: {760, 420})
    panel = :wxPanel.new(frame)
    font = :wxFont.new(12, @teletype, @normal, @normal)

    clear = :wxButton.new(panel, @clear_id, label: ~c"Clear")
    log = :wxTextCtrl.new(panel, -1, style: @te_log)
    :wxWindow.setBackgroundColour(log, {255, 255, 255})
    :wxWindow.setFont(log, font)
    prompt = :wxStaticText.new(panel, -1, ~c"›")
    input = :wxTextCtrl.new(panel, @input_id, style: @te_process_enter)
    :wxWindow.setFont(input, font)

    top = :wxBoxSizer.new(@horizontal)
    :wxSizer.add(top, clear, border: 4, flag: @all)
    bottom = :wxBoxSizer.new(@horizontal)
    :wxSizer.add(bottom, prompt, border: 4, flag: @all)
    :wxSizer.add(bottom, input, proportion: 1, border: 4, flag: @all)
    col = :wxBoxSizer.new(@vertical)
    :wxSizer.add(col, top, flag: @expand)
    :wxSizer.add(col, log, proportion: 1, flag: @expand)
    :wxSizer.add(col, bottom, flag: @expand)
    :wxWindow.setSizer(panel, col)

    :wxButton.connect(clear, :command_button_clicked)
    :wxTextCtrl.connect(input, :command_text_enter)

    # closing the window only hides it
    :wxFrame.connect(frame, :close_window, callback: fn _event, _obj -> :wxWindow.hide(frame) end)

    %__MODULE__{frame: frame, log: log, input: input, clear: clear}
  end

  def show(%{frame: frame, input: input}) do
    :wxWindow.show(frame)
    :wxWindow.raise(frame)
    :wxWindow.setFocus(input)
  end

  def shown?(%{frame: frame}), do: :wxWindow.isShown(frame)

  def set_title(%{frame: frame}, title),
    do: :wxFrame.setTitle(frame, String.to_charlist("Console — " <> title))

  @doc "Empties the log view."
  def clear(%{log: log}), do: :wxTextCtrl.clear(log)

  @doc "Takes the text in the input line and empties it."
  def take_input(%{input: input}) do
    text = :wxTextCtrl.getValue(input) |> to_string()
    :wxTextCtrl.setValue(input, ~c"")
    text
  end

  def put_input(%{input: input}, text) do
    :wxTextCtrl.setValue(input, String.to_charlist(text))
    :wxTextCtrl.setInsertionPointEnd(input)
  end

  @doc "Adds entries (`Browser.Console.entry/0`) to the end of the view."
  def append(_win, []), do: :ok

  def append(%{log: log}, entries) do
    for {_seq, level, text, time} <- entries do
      {fg, bg} = colours(level)
      attr = :wxTextAttr.new(fg, colBack: bg)
      :wxTextCtrl.setDefaultStyle(log, attr)
      :wxTextAttr.destroy(attr)
      :wxTextCtrl.appendText(log, line(level, text, time))
    end

    :wxTextCtrl.showPosition(log, :wxTextCtrl.getLastPosition(log))
  end

  @doc "The text of one entry, as the view shows it."
  def line(level, text, time) do
    {_, {h, m, s}} = :calendar.system_time_to_local_time(time, :millisecond)
    stamp = :io_lib.format(~c"~2..0B:~2..0B:~2..0B ", [h, m, s]) |> to_string()
    mark = Map.get(%{input: "› ", result: "← ", warn: "⚠ ", error: "✖ "}, level, "")
    String.to_charlist(stamp <> mark <> text <> "\n")
  end

  # text and background colour of each level
  defp colours(:log), do: {{40, 40, 40}, {255, 255, 255}}
  defp colours(:warn), do: {{110, 75, 0}, {255, 248, 220}}
  defp colours(:error), do: {{165, 20, 20}, {255, 235, 235}}
  defp colours(:input), do: {{0, 70, 160}, {255, 255, 255}}
  defp colours(:result), do: {{90, 90, 90}, {255, 255, 255}}
end
