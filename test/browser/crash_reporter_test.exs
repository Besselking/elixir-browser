defmodule Browser.CrashReporterTest do
  use ExUnit.Case, async: false

  alias Browser.CrashReporter

  setup do
    dir = Path.join(System.tmp_dir!(), "crashes-#{System.unique_integer([:positive])}")
    System.put_env("BROWSER_CRASH_DIR", dir)
    CrashReporter.install()

    on_exit(fn ->
      System.delete_env("BROWSER_CRASH_DIR")
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp wait_for(dir, n \\ 50) do
    case CrashReporter.list(dir) do
      [] when n > 0 ->
        Process.sleep(20)
        wait_for(dir, n - 1)

      files ->
        files
    end
  end

  test "a crashing process leaves one file with page, version and stacktrace", %{dir: dir} do
    CrashReporter.set_page("http://example.test/broken")
    {:ok, pid} = Task.Supervisor.start_link()
    Process.flag(:trap_exit, true)

    {:ok, _} =
      Task.Supervisor.start_child(pid, fn -> raise "boom from test" end, restart: :temporary)

    [file] = wait_for(dir)
    Process.sleep(100)
    assert [^file] = CrashReporter.list(dir)
    body = File.read!(Path.join(dir, file))
    assert body =~ "page: http://example.test/broken"
    assert body =~ "boom from test"
    assert body =~ "commit: "
    assert body =~ "version: "
  end

  test "Logger.error is saved too", %{dir: dir} do
    require Logger
    Logger.error("plain logged failure")
    [file] = wait_for(dir)
    assert File.read!(Path.join(dir, file)) =~ "plain logged failure"
  end

  test "an empty BROWSER_CRASH_DIR falls back to the config (off in tests)", %{dir: _} do
    System.put_env("BROWSER_CRASH_DIR", "")
    assert CrashReporter.dir() == nil
  end
end
