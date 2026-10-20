defmodule Browser.JS.Editing do
  @moduledoc """
  `Range`, `Selection` and `document.execCommand`: the JavaScript in `priv/js/editing.js`, run
  the first time a page asks for the selection, a range or a command (a stub in the web API
  prelude calls `__load_editing`), or when the session first hands the runtime a key for an
  editing host. Pages that never edit do not pay for it, and the methods it wraps to keep
  ranges up to date stay as they are.
  """

  alias Browser.JS.{Interp, Parser}

  @source Path.expand("../../../priv/js/editing.js", __DIR__)
  @external_resource @source
  @code File.read!(@source)

  @doc "Declares `__load_editing`, which the stubs in the prelude call."
  def install(scope) do
    Interp.declare(
      scope,
      "__load_editing",
      Interp.native("__load_editing", fn _this, _args ->
        load()
        :undefined
      end)
    )
  end

  @doc """
  Runs the editing prelude once in each realm of this runtime. The prelude belongs to the realm
  it runs in: it keeps the realm's document, and the functions that it puts on the shared
  prototypes (`Node.prototype.appendChild`, `document.execCommand`) are closures of that realm.
  When a frame goes, these go back to their boot state (`Browser.JS.Intrinsics`), so the next
  realm that edits runs the prelude again. The documents that have it are in
  `:editing_loaded`.
  """
  def load do
    doc = Browser.JS.DOM.current_doc_or_nil()
    loaded = Process.get(:editing_loaded) || MapSet.new()

    unless MapSet.member?(loaded, doc) do
      Process.put(:editing_loaded, MapSet.put(loaded, doc))

      case program() do
        {:ok, ast} -> Interp.run_program(ast)
        {:error, msg} -> throw({:syntax, "editing prelude: " <> msg})
      end
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
