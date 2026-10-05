defmodule Mix.Tasks.Browser.Crashes do
  @shortdoc "Lists the saved crash reports (--show prints them, --clear deletes them)"

  @moduledoc """
  Lists the crash reports `Browser.CrashReporter` has saved, oldest first.

      mix browser.crashes           # the file names
      mix browser.crashes --show    # and their contents
      mix browser.crashes --clear   # delete them all
  """
  use Mix.Task

  alias Browser.CrashReporter

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [show: :boolean, clear: :boolean])
    dir = CrashReporter.dir()
    files = dir |> CrashReporter.list() |> Enum.reverse()

    cond do
      is_nil(dir) -> Mix.shell().info("crash reporting is off")
      files == [] -> Mix.shell().info("no crashes in #{dir}")
      opts[:clear] -> Enum.each(files, &File.rm(Path.join(dir, &1)))
      opts[:show] -> Enum.each(files, &show(Path.join(dir, &1)))
      true -> Enum.each(files, &Mix.shell().info(Path.join(dir, &1)))
    end
  end

  defp show(path), do: Mix.shell().info("== #{path}\n#{File.read!(path)}")
end
