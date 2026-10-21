defmodule Browser.Pickers do
  @moduledoc """
  The values of the inputs that have a native picker (`<input type=color | date | datetime-local
  | month | week>`): reading the text of a value, and writing the choice back as text. The
  dialogs themselves are in `Browser.UI`.
  """

  @doc "`#rrggbb` for a valid colour text (any case), else black."
  def color_value(text) do
    case Regex.run(~r/\A#([0-9a-fA-F]{6})\z/, String.trim(to_string(text))) do
      [_, hex] -> "#" <> String.downcase(hex)
      nil -> "#000000"
    end
  end

  @doc "The `{r, g, b}` of a colour text."
  def rgb(text) do
    "#" <> hex = color_value(text)
    <<r, g, b>> = Base.decode16!(hex, case: :lower)
    {r, g, b}
  end

  @doc "The text of an `{r, g, b}` colour."
  def color_text({r, g, b}), do: color_value("#" <> Base.encode16(<<r, g, b>>, case: :lower))

  @doc "The date that the text of a field of `type` shows (today when it shows none)."
  def date_of("date", text), do: iso(text) || Date.utc_today()

  def date_of("datetime-local", text),
    do: text |> to_string() |> String.slice(0, 10) |> iso() || Date.utc_today()

  def date_of("month", text), do: iso(to_string(text) <> "-01") || Date.utc_today()

  def date_of("week", text) do
    case Regex.run(~r/\A(\d{4})-W(\d{2})\z/, to_string(text)) do
      [_, y, w] ->
        {year, week} = {String.to_integer(y), String.to_integer(w)}
        jan4 = Date.new!(year, 1, 4)
        Date.add(jan4, -(Date.day_of_week(jan4) - 1) + (week - 1) * 7)

      nil ->
        Date.utc_today()
    end
  end

  defp iso(text) do
    case Date.from_iso8601(to_string(text)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  @doc "The text of a field of `type` after the user chose `date` (`old` is what it held)."
  def date_text("date", date, _old), do: Date.to_iso8601(date)
  def date_text("month", date, _old), do: String.slice(Date.to_iso8601(date), 0, 7)

  def date_text("week", date, _old) do
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    "#{year}-W#{week |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  def date_text("datetime-local", date, old) do
    time =
      case Regex.run(~r/T(\d{2}:\d{2}(?::\d{2})?)\z/, to_string(old)) do
        [_, t] -> t
        nil -> "00:00"
      end

    Date.to_iso8601(date) <> "T" <> time
  end
end
