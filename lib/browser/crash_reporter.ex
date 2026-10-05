defmodule Browser.CrashReporter do
  @moduledoc """
  Saves every crash as a text file, so a bug can be found and fixed without anyone having
  to spot it.

  A `:logger` handler picks up everything logged at error level or above (a process that
  dies, a `GenServer` terminating, a wx callback raising, `Logger.error/1`) and writes one
  file per crash to `dir/0`: the time, the page that was open, the app version and commit,
  and the report as OTP formats it, stacktrace included.

  The folder is `$BROWSER_CRASH_DIR`, else config `:crash_dir`, else `crashes/` under the
  user data dir (`nil` in config turns reporting off). It keeps the newest #{100} files.
  """

  @handler_id :browser_crash_reporter
  @keep 100
  # a process that crashes is reported twice (by its behaviour and by proc_lib); one file is enough
  @dedupe_ms 2_000
  @seen :browser_crash_seen

  @commit (try do
             case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
               {sha, 0} -> String.trim(sha)
               _ -> "unknown"
             end
           rescue
             _ -> "unknown"
           end)

  @doc "Where crash files go; `nil` when reporting is off."
  def dir do
    case System.get_env("BROWSER_CRASH_DIR") do
      dir when dir in [nil, ""] ->
        case Application.fetch_env(:browser, :crash_dir) do
          {:ok, dir} ->
            dir

          :error ->
            Path.join(
              :filename.basedir(:user_data, ~c"elixir_browser") |> to_string(),
              "crashes"
            )
        end

      dir ->
        dir
    end
  end

  @doc "Installs the logger handler. Called once as the application starts."
  def install do
    if :ets.whereis(@seen) == :undefined,
      do: :ets.new(@seen, [:named_table, :public, :set])

    case :logger.add_handler(@handler_id, __MODULE__, %{level: :error}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end

  @doc "Remembers the page that is open, to name in the next crash report."
  def set_page(url), do: Application.put_env(:browser, :crash_page, url)

  @doc "The crash files, newest first."
  def list(dir \\ dir()) do
    case dir && File.ls(dir) do
      {:ok, names} ->
        names |> Enum.filter(&String.starts_with?(&1, "crash-")) |> Enum.sort(:desc)

      _ ->
        []
    end
  end

  # ── :logger handler ────────────────────────────────────────

  @doc false
  def log(%{level: level} = event, _config)
      when level in [:error, :critical, :alert, :emergency] do
    try do
      with dir when is_binary(dir) <- dir(), true <- fresh?(event) do
        write(dir, event)
      end
    catch
      # a failing reporter must never take the process it is reporting on down with it
      _, _ -> :ok
    end

    :ok
  end

  def log(_event, _config), do: :ok

  defp fresh?(event) do
    pid = Map.get(event.meta, :pid, self())
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@seen, pid) do
      [{_, at}] when now - at < @dedupe_ms ->
        false

      _ ->
        :ets.insert(@seen, {pid, now})
        true
    end
  end

  defp write(dir, event) do
    File.mkdir_p!(dir)
    now = DateTime.utc_now()
    stamp = Calendar.strftime(now, "%Y%m%dT%H%M%S")
    name = "crash-#{stamp}-#{:erlang.unique_integer([:positive])}.txt"
    path = Path.join(dir, name)

    body =
      """
      time: #{DateTime.to_iso8601(now)}
      page: #{Application.get_env(:browser, :crash_page, "none")}
      version: #{Application.spec(:browser, :vsn)}
      commit: #{@commit}
      otp: #{:erlang.system_info(:otp_release)}
      elixir: #{System.version()}
      level: #{event.level}
      process: #{inspect(Map.get(event.meta, :pid))}

      #{format(event)}
      """

    File.write!(path <> ".tmp", body)
    File.rename!(path <> ".tmp", path)
    prune(dir)
  end

  defp format(event) do
    :logger_formatter.format(event, %{template: [:msg], single_line: false, chars_limit: 20_000})
    |> IO.chardata_to_string()
    |> String.trim()
  end

  defp prune(dir) do
    for name <- list(dir) |> Enum.drop(@keep), do: File.rm(Path.join(dir, name))
  end
end
