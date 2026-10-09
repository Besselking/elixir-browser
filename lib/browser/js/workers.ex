defmodule Browser.JS.Workers do
  @moduledoc """
  The page side of dedicated workers: `Worker` (the JavaScript in `priv/js/worker.js`, run the
  first time a script uses the name) and the natives it stands on.

  Every worker is an Elixir process (`Browser.JS.Worker`) with a JS heap of its own. A message is
  the structured clone of a value as text (`__structuredEncode`), so nothing but a binary
  crosses from one heap to the other. What the worker does reaches the process of the page as
  `{:worker, id, event}`: `{:message, text}`, `{:error, message, file}` and `{:console, lines}`;
  the runtime hands each to `deliver/2`.
  """

  alias Browser.JS.{Interp, Parser}

  @source Path.expand("../../../priv/js/worker.js", __DIR__)
  @external_resource @source
  @code File.read!(@source)

  @doc "Declares the natives of the script and `__load_workers`."
  def install(scope) do
    def_fn(scope, "__load_workers", fn _ ->
      load()
      :undefined
    end)

    # the script says which function hears of what the workers do
    def_fn(scope, "__worker_hook", fn [f | _] ->
      Process.put(:worker_hook, f)
      :undefined
    end)

    # (id, url, source | undefined, name, module?) -> starts the worker
    def_fn(scope, "__worker_start", fn [id, url, source, name, module? | _] ->
      id = trunc(id)

      spec = %{
        url: Interp.to_str(url),
        source: if(is_binary(source), do: source),
        name: Interp.to_str(name),
        module?: module? == true
      }

      pid = Browser.JS.Worker.start(self(), id, spec, Process.get(:rt_info))
      Process.put(:workers, Map.put(Process.get(:workers, %{}), id, pid))
      :undefined
    end)

    def_fn(scope, "__worker_post", fn [id, text | _] ->
      with pid when is_pid(pid) <- Map.get(Process.get(:workers, %{}), trunc(id)),
           do: send(pid, {:message, Interp.to_str(text)})

      :undefined
    end)

    def_fn(scope, "__worker_terminate", fn [id | _] ->
      id = trunc(id)

      with pid when is_pid(pid) <- Map.get(Process.get(:workers, %{}), id) do
        Process.exit(pid, :kill)
        Process.put(:workers, Map.delete(Process.get(:workers), id))
      end

      :undefined
    end)
  end

  @doc false
  def def_fn(scope, name, fun) do
    Interp.declare(
      scope,
      name,
      Interp.native(name, fn _this, args -> fun.(args ++ List.duplicate(:undefined, 5)) end)
    )
  end

  @doc "Runs the script once in this runtime."
  def load do
    unless Process.get(:workers_loaded) do
      Process.put(:workers_loaded, true)

      case program() do
        {:ok, ast} -> Interp.run_program(ast)
        {:error, msg} -> throw({:syntax, "worker: " <> msg})
      end
    end

    :ok
  end

  @doc "What worker `id` did reaches the page's scripts."
  def deliver(id, {:console, lines}) do
    Process.put(:js_console, Enum.reverse(lines) ++ Process.get(:js_console, []))
    _ = id
    :ok
  end

  def deliver(id, event) do
    with f when f != nil <- Process.get(:worker_hook) do
      args =
        case event do
          {:message, text} -> ["message", id * 1.0, text]
          {:error, message, file} -> ["error", id * 1.0, message, file]
        end

      Interp.call(f, :undefined, args)
    end

    :ok
  end

  defp program do
    case :persistent_term.get({__MODULE__, :ast}, nil) do
      nil ->
        with {:ok, ast} <- Parser.parse(@code) do
          :persistent_term.put({__MODULE__, :ast}, {:ok, ast})
          {:ok, ast}
        end

      cached ->
        cached
    end
  end
end
