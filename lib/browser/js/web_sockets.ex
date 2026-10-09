defmodule Browser.JS.WebSockets do
  @moduledoc """
  `WebSocket` for scripts: the JavaScript in `priv/js/websocket.js` (run the first time a script
  uses the name) and the natives it stands on. Each connection is a process
  (`Browser.WebSocket.Client`) that reports to the process of the page as `{:ws, id, event}`;
  the runtime hands each event to `deliver/2`.
  """

  alias Browser.JS.{Interp, Parser, TypedArrays}

  @source Path.expand("../../../priv/js/websocket.js", __DIR__)
  @external_resource @source
  @code File.read!(@source)

  @doc "Declares the natives of the script and `__load_websocket`."
  def install(scope) do
    def_fn(scope, "__load_websocket", fn _ ->
      load()
      :undefined
    end)

    def_fn(scope, "__ws_hook", fn [f | _] ->
      Process.put(:ws_hook, f)
      :undefined
    end)

    # (id, url, protocols, origin, page url) -> starts the connection
    def_fn(scope, "__ws_start", fn [id, url, protocols, origin, page_url | _] ->
      id = trunc(id)

      opts = [
        protocols: for(p <- Interp.array_list(protocols), do: Interp.to_str(p)),
        origin: Interp.to_str(origin),
        page_url: Interp.to_str(page_url)
      ]

      pid = Browser.WebSocket.Client.start(self(), id, Interp.to_str(url), opts)
      Process.put(:websockets, Map.put(Process.get(:websockets, %{}), id, pid))
      :undefined
    end)

    # (id, data, binary?): text is a string, binary an ArrayBuffer
    def_fn(scope, "__ws_send", fn [id, data, binary? | _] ->
      with pid when is_pid(pid) <- Map.get(Process.get(:websockets, %{}), trunc(id)) do
        if binary? == true,
          do: send(pid, {:send, :binary, TypedArrays.buffer_bytes(data) || ""}),
          else: send(pid, {:send, :text, Interp.to_str(data)})
      end

      :undefined
    end)

    def_fn(scope, "__ws_close", fn [id, code, reason | _] ->
      with pid when is_pid(pid) <- Map.get(Process.get(:websockets, %{}), trunc(id)) do
        code = if is_number(code), do: trunc(code)
        send(pid, {:close, code, if(is_binary(reason), do: reason, else: "")})
      end

      :undefined
    end)
  end

  defp def_fn(scope, name, fun) do
    Interp.declare(
      scope,
      name,
      Interp.native(name, fn _this, args -> fun.(args ++ List.duplicate(:undefined, 5)) end)
    )
  end

  @doc "Runs the script once in this runtime."
  def load do
    unless Process.get(:websocket_loaded) do
      Process.put(:websocket_loaded, true)

      case program() do
        {:ok, ast} -> Interp.run_program(ast)
        {:error, msg} -> throw({:syntax, "websocket: " <> msg})
      end
    end

    :ok
  end

  @doc "What connection `id` did reaches the script."
  def deliver(id, event) do
    with f when f != nil <- Process.get(:ws_hook) do
      args =
        case event do
          {:open, protocol} ->
            ["open", id * 1.0, protocol]

          {:message, :text, data} ->
            ["message", id * 1.0, data, false]

          {:message, :binary, data} ->
            ["message", id * 1.0, TypedArrays.make_buffer(data), true]

          :error ->
            ["error", id * 1.0]

          {:closed, code, reason, clean?} ->
            Process.put(:websockets, Map.delete(Process.get(:websockets, %{}), id))
            ["close", id * 1.0, code * 1.0, reason, clean?]
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
