defmodule Browser.Wasm do
  @moduledoc """
  A WebAssembly engine written in Elixir: a binary decoder (`Browser.Wasm.Decoder`), a validator
  that also flattens the code (`Browser.Wasm.Validator`) and an interpreter
  (`Browser.Wasm.Interp`). The JavaScript `WebAssembly` object sits on top of this module.

  Supported: the WebAssembly 2.0 core without SIMD (multi-value, reference types, bulk memory,
  sign extension, saturating conversions) plus tail calls, multiple memories and extended constant expressions. Errors are `Browser.Wasm.Error` with kind `:compile`,
  `:link` or `:trap`.
  """

  alias Browser.Wasm.{Decoder, Instance, Interp, Validator}

  @doc "Decodes and validates a binary. Returns the module."
  def compile(bin), do: bin |> Decoder.decode() |> Validator.validate()

  @doc "`true` when `bin` is a valid module."
  def valid?(bin) do
    compile(bin)
    true
  rescue
    Browser.Wasm.Error -> false
  end

  @doc "The imports of a module: `[%{module:, name:, kind:}]` with the descriptor of each (a function has its `{params, results}` type)."
  def imports(mod) do
    types = List.to_tuple(mod.types)

    for i <- mod.imports do
      desc =
        case i.desc do
          {:func, t} -> {:func, elem(types, t)}
          other -> other
        end

      %{module: i.module, name: i.name, kind: elem(desc, 0), desc: desc}
    end
  end

  @doc "The exports of a module: `[%{name:, kind:}]`."
  def exports(mod), do: for(e <- mod.exports, do: %{name: e.name, kind: e.kind})

  @doc "The custom sections called `name`."
  def custom_sections(mod, name), do: for({^name, data} <- mod.customs, do: data)

  defdelegate instantiate(mod, resolve), to: Instance

  @doc "Calls a function instance with a list of values. Returns the list of results."
  def invoke(func, args), do: Interp.invoke(func, args, 0)
end
