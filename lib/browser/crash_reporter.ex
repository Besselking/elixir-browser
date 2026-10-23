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
  @trail :browser_crash_trail
  @trail_keep 80

  # the commit is read when this file is compiled, so the build must see a new commit:
  # `.git/HEAD` changes on checkout, the branch file on commit, `packed-refs` after `git gc`
  @git_files (case File.read(".git/HEAD") do
                {:ok, "ref: " <> ref} ->
                  [".git/HEAD", Path.join(".git", String.trim(ref)), ".git/packed-refs"]

                _ ->
                  [".git/HEAD"]
              end)
  for file <- @git_files, do: @external_resource(file)

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

    if :ets.whereis(@trail) == :undefined,
      do: :ets.new(@trail, [:named_table, :public, :ordered_set])

    adopt_native_crash()

    case :logger.add_handler(@handler_id, __MODULE__, %{level: :error}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end

  @doc """
  Notes `what` happened (in the calling process) for the next crash report. A wx assert is
  logged after the call that caused it is over, so the report lists the last events instead.
  The same event twice in a row from one process is kept once.
  """
  def breadcrumb(what) do
    if :ets.whereis(@trail) != :undefined do
      case :ets.last(@trail) do
        :"$end_of_table" -> :ok
        key -> key
      end
      |> case do
        key when is_integer(key) ->
          case :ets.lookup(@trail, key) do
            [{_, _, pid, ^what}] when pid == self() -> :same
            _ -> :new
          end

        _ ->
          :new
      end
      |> case do
        :same ->
          :ok

        :new ->
          :ets.insert(
            @trail,
            {System.unique_integer([:monotonic]), System.monotonic_time(:millisecond), self(),
             what}
          )

          if :ets.info(@trail, :size) > @trail_keep, do: :ets.delete(@trail, :ets.first(@trail))
          append_trail(what)
          :ok
      end
    end

    :ok
  end

  # The ETS trail dies with the VM. A native crash (SIGBUS) gives no chance to write a report,
  # so every breadcrumb is also appended to a file. A clean quit deletes the file; the next
  # start turns a file that is still there into a crash report.
  defp trail_file do
    case dir() do
      nil -> nil
      dir -> Path.join(dir, "running-trail.log")
    end
  end

  defp append_trail(what) do
    if file = trail_file() do
      File.mkdir_p(Path.dirname(file))

      case File.stat(file) do
        {:ok, %{size: size}} when size > 200_000 -> File.rm(file)
        _ -> :ok
      end

      line = "#{System.os_time(:millisecond)} #{inspect(self())} #{inspect(what, limit: 20)}\n"
      File.write(file, line, [:append])
    end

    :ok
  end

  @doc "Deletes the running trail: the program is ending in order."
  def clean_exit do
    if file = trail_file(), do: File.rm(file)
    :ok
  end

  defp adopt_native_crash do
    with file when is_binary(file) <- trail_file(),
         {:ok, text} <- File.read(file) do
      lines = text |> String.split("\n", trim: true) |> Enum.take(-80)

      out =
        Path.join(
          Path.dirname(file),
          "crash-#{System.os_time(:second)}-native.txt"
        )

      File.write(
        out,
        "The last run ended without a clean quit (a native crash such as SIGBUS).\n" <>
          "Last events before it ended:\n" <> Enum.join(lines, "\n") <> "\n"
      )

      File.rm(file)
    end

    :ok
  end

  @doc "Remembers the page that is open, to name in the next crash report."
  def set_page(url), do: Application.put_env(:browser, :crash_page, url)

  @doc "The crash files, newest first."
  def list(dir \\ dir()) do
    case dir && File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(String.starts_with?(&1, "crash-") and not String.ends_with?(&1, ".tmp")))
        |> Enum.sort(:desc)

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

      #{format(event)}#{wx_section()}#{trail_section()}
      """

    File.write!(path <> ".tmp", body)
    File.rename!(path <> ".tmp", path)
    prune(dir)
  end

  # A wx assert comes from the toolkit's thread and carries no Elixir stack. The processes that
  # are inside a wx call (or a wx callback) just now are the ones that can have caused it.
  defp wx_section do
    case stacks([:wxe_util, :wxe_server]) do
      [] -> ""
      found -> "\n\nprocesses in wx calls:\n\n" <> Enum.join(found, "\n\n")
    end
  end

  defp trail_section do
    now = System.monotonic_time(:millisecond)

    case if(:ets.whereis(@trail) == :undefined, do: [], else: :ets.tab2list(@trail)) do
      [] ->
        ""

      rows ->
        lines =
          for {_, at, pid, what} <- rows,
              do: "  -#{now - at} ms  #{inspect(pid)}  #{inspect(what, limit: 8)}"

        "\n\nrecent events (oldest first, ms before this report):\n\n" <> Enum.join(lines, "\n")
    end
  end

  @doc false
  # The stacks of the processes that have a frame in one of `modules`.
  def stacks(modules) do
    for pid <- Process.list(),
        pid != self(),
        {:current_stacktrace, stack} <- [Process.info(pid, :current_stacktrace)],
        Enum.any?(stack, fn {mod, _, _, _} -> mod in modules end) do
      name =
        case Process.info(pid, :registered_name) do
          {:registered_name, name} when is_atom(name) -> " (#{name})"
          _ -> ""
        end

      frames =
        stack
        |> Enum.take(30)
        |> Enum.map_join("\n", &("  " <> Exception.format_stacktrace_entry(&1)))

      "#{inspect(pid)}#{name}\n#{frames}"
    end
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
