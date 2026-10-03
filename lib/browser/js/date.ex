defmodule Browser.JS.Date do
  @moduledoc """
  `Date`: a time value in milliseconds since the epoch, kept in the `:date` field of the heap
  object. Local time is UTC (the runtime has no time zones).
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]

  @ms_day 86_400_000
  @max_time 8.64e15
  @days ~w(Sun Mon Tue Wed Thu Fri Sat)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp arg(args, i), do: Enum.at(args, i, :undefined)

  def install(scope) do
    proto = new_object()
    put_proto(:date, proto)

    ctor =
      native("Date", fn this, args ->
        if date_target?(this) do
          store_time(this, construct_time(args))
        else
          to_string_time(now())
        end
      end)

    put_hidden(ctor, "prototype", proto)
    put_hidden(proto, "constructor", ctor)
    declare(scope, "Date", ctor)

    def_fn(ctor, "now", fn _, _ -> now() end)
    def_fn(ctor, "parse", fn _, args -> parse(to_str(arg(args, 0))) end)
    def_fn(ctor, "UTC", fn _, args -> from_parts(args) end)

    def_fn(proto, "getTime", fn this, _ -> time!(this) end)
    def_fn(proto, "valueOf", fn this, _ -> time!(this) end)

    def_fn(proto, "getTimezoneOffset", fn this, _ ->
      if time!(this) == :nan, do: :nan, else: 0.0
    end)

    fields = [
      {"FullYear", 0},
      {"Month", 1},
      {"Date", 2},
      {"Hours", 3},
      {"Minutes", 4},
      {"Seconds", 5},
      {"Milliseconds", 6},
      {"Day", 7}
    ]

    for {name, i} <- fields, prefix <- ["get", "getUTC"] do
      def_fn(proto, prefix <> name, fn this, _ ->
        case time!(this) do
          :nan -> :nan
          t -> Enum.at(parts(t), i) * 1.0
        end
      end)
    end

    for {name, i} <- Enum.take(fields, 7), prefix <- ["set", "setUTC"] do
      def_fn(proto, prefix <> name, fn this, args ->
        t = time!(this)
        base = if t == :nan, do: [1970, 0, 1, 0, 0, 0, 0], else: Enum.take(parts(t), 7)
        nums = Enum.map(args, &to_num/1)

        new =
          if nums == [] or :nan in nums or (t == :nan and i != 0) do
            :nan
          else
            from_parts(List.replace_at(Enum.map(base, &(&1 * 1.0)), i, hd(nums)))
          end

        store_time(this, new)
        new
      end)
    end

    def_fn(proto, "setTime", fn this, args ->
      store_time(this, clip(to_num(arg(args, 0)))) |> time!()
    end)

    def_fn(proto, "toISOString", fn this, _ ->
      case time!(this) do
        :nan -> throw_error("RangeError", "Invalid time value")
        t -> iso(t)
      end
    end)

    def_fn(proto, "toJSON", fn this, _ ->
      case time!(this) do
        :nan -> :null
        t -> iso(t)
      end
    end)

    for name <- ["toString", "toUTCString", "toDateString", "toTimeString", "toLocaleString"] do
      def_fn(proto, name, fn this, _ -> to_string_time(time!(this)) end)
    end
  end

  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))

  defp date_target?({:obj, id}) do
    o = deref(id)
    not Map.has_key?(o, :date) and o.proto == proto(:date)
  end

  defp date_target?(_), do: false

  defp store_time({:obj, id} = o, t) do
    store(id, Map.put(deref(id), :date, t))
    o
  end

  defp time!({:obj, id}) do
    case Map.fetch(deref(id), :date) do
      {:ok, t} -> t
      :error -> throw_error("TypeError", "this is not a Date object")
    end
  end

  defp time!(_), do: throw_error("TypeError", "this is not a Date object")

  defp now, do: System.system_time(:millisecond) * 1.0

  defp construct_time([]), do: now()

  defp construct_time([v]) do
    v =
      case v do
        {:obj, id} ->
          case Map.fetch(deref(id), :date) do
            {:ok, t} -> t
            :error -> to_primitive(v, "default")
          end

        _ ->
          v
      end

    case v do
      s when is_binary(s) -> parse(s)
      other -> clip(to_num(other))
    end
  end

  defp construct_time(args), do: from_parts(args)

  # a time value in range, truncated, or NaN
  defp clip(:nan), do: :nan
  defp clip(n) when n in [:infinity, :neg_infinity], do: :nan
  defp clip(n) when abs(n) > @max_time, do: :nan
  defp clip(n), do: (trunc(n) + 0) * 1.0

  # year, month, [day, h, m, s, ms] -> time value; years 0..99 mean 1900..1999
  defp from_parts(args) do
    nums = Enum.map(args, &to_num/1)
    defaults = [nil, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]
    nums = Enum.with_index(defaults) |> Enum.map(fn {d, i} -> Enum.at(nums, i, d) end)

    if args == [] or Enum.any?(nums, &(not is_number(&1))) do
      :nan
    else
      [y, m, d, h, mi, s, ms] = Enum.map(nums, &trunc/1)
      y = if y in 0..99, do: 1900 + y, else: y
      days = days_from_civil(y + Integer.floor_div(m, 12), Integer.mod(m, 12) + 1, 1) + d - 1
      clip((days * @ms_day + h * 3_600_000 + mi * 60_000 + s * 1000 + ms) * 1.0)
    end
  end

  # [year, month0, day, hours, minutes, seconds, ms, weekday]
  defp parts(t) do
    t = trunc(t)
    days = Integer.floor_div(t, @ms_day)
    ms = Integer.mod(t, @ms_day)
    {y, m, d} = civil_from_days(days)

    [
      y,
      m - 1,
      d,
      div(ms, 3_600_000),
      div(rem(ms, 3_600_000), 60_000),
      div(rem(ms, 60_000), 1000),
      rem(ms, 1000),
      Integer.mod(days + 4, 7)
    ]
  end

  # Howard Hinnant's civil-date algorithms
  defp days_from_civil(y, m, d) do
    y = if m <= 2, do: y - 1, else: y
    era = Integer.floor_div(y, 400)
    yoe = y - era * 400
    doy = div(153 * (m + if(m > 2, do: -3, else: 9)) + 2, 5) + d - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146_097 + doe - 719_468
  end

  defp civil_from_days(z) do
    z = z + 719_468
    era = Integer.floor_div(z, 146_097)
    doe = z - era * 146_097
    yoe = div(doe - div(doe, 1460) + div(doe, 36_524) - div(doe, 146_096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = if mp < 10, do: mp + 3, else: mp - 9
    {if(m <= 2, do: y + 1, else: y), m, d}
  end

  defp iso(t) do
    [y, m, d, h, mi, s, ms | _] = parts(t)

    year =
      cond do
        y in 0..9999 -> pad(y, 4)
        y < 0 -> "-" <> pad(-y, 6)
        true -> "+" <> pad(y, 6)
      end

    "#{year}-#{pad(m + 1, 2)}-#{pad(d, 2)}T#{pad(h, 2)}:#{pad(mi, 2)}:#{pad(s, 2)}.#{pad(ms, 3)}Z"
  end

  defp pad(n, w), do: n |> Integer.to_string() |> String.pad_leading(w, "0")

  defp to_string_time(:nan), do: "Invalid Date"

  defp to_string_time(t) do
    [y, m, d, h, mi, s, _, wd] = parts(t)

    "#{Enum.at(@days, wd)} #{Enum.at(@months, m)} #{pad(d, 2)} #{pad(y, 4)} " <>
      "#{pad(h, 2)}:#{pad(mi, 2)}:#{pad(s, 2)} GMT+0000 (UTC)"
  end

  # ISO format (and the toString format is not read back)
  defp parse(s) do
    re =
      ~r/\A([+-]\d{6}|\d{4})(?:-(\d\d)(?:-(\d\d))?)?(?:T(\d\d):(\d\d)(?::(\d\d)(?:\.(\d{1,3})\d*)?)?(Z|[+-]\d\d:\d\d)?)?\z/

    case Regex.run(re, s) do
      nil ->
        :nan

      [_, y | rest] ->
        rest = rest ++ List.duplicate("", 8 - length(rest))
        [mo, d, h, mi, sec, ms, tz] = Enum.take(rest, 7)

        n = fn v, default -> if v == "", do: default, else: String.to_integer(v) end

        ms = if ms == "", do: 0, else: String.to_integer(String.pad_trailing(ms, 3, "0"))

        offset =
          case tz do
            <<sign, hh::binary-size(2), ":", mm::binary-size(2)>> ->
              if(sign == ?-, do: -1, else: 1) *
                (String.to_integer(hh) * 60 + String.to_integer(mm)) * 60_000

            _ ->
              0
          end

        month = n.(mo, 1)
        day = n.(d, 1)

        if month in 1..12 and day in 1..31 and n.(h, 0) <= 24 and n.(mi, 0) <= 59 and
             n.(sec, 0) <= 59 do
          t =
            days_from_civil(String.to_integer(y), month, day) * @ms_day + n.(h, 0) * 3_600_000 +
              n.(mi, 0) * 60_000 + n.(sec, 0) * 1000 + ms - offset

          clip(t * 1.0)
        else
          :nan
        end
    end
  end
end
