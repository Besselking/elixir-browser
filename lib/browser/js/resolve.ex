defmodule Browser.JS.Resolve do
  @moduledoc """
  The resolver: a pass over a parsed program that finds the scope of every
  name and attaches the facts the interpreter needs to run a function with
  slot frames.

  The pass is pure. It runs once per parsed program, after the parser, and
  only when the resolve level is not `:off`. With the level `:off` the program
  term does not change. With the level `:info` the pass attaches an `Info` to
  every function node and rewrites nothing. With a level from 1 to 4 the pass
  also rewrites the names of every function whose own level is that number or
  lower.

  This module holds the helpers the interpreter uses to read the sixth element
  of a `{:fn, name, params, body, mode, src}` node, which is a source text, `nil`
  or an `Info` that carries the source text.
  """

  alias Browser.JS.Resolve.Info

  @doc """
  Splits the sixth element of a function node into the source text and the
  `Info`. Returns `{src, nil}` when the resolver did not run.
  """
  @spec unpack(binary | nil | Info.t()) :: {binary | nil, Info.t() | nil}
  def unpack(%Info{src: src} = info), do: {src, info}
  def unpack(src), do: {src, nil}

  @doc """
  Gives a function node's sixth element a new source text and keeps its `Info`.
  A plain source text gives the new text back.
  """
  @spec with_src(binary | nil | Info.t(), binary | nil) :: binary | nil | Info.t()
  def with_src(%Info{} = info, src), do: %{info | src: src}
  def with_src(_, src), do: src

  @doc """
  The `Info` of a function node, or `nil` when the resolver did not run.
  """
  @spec info(tuple) :: Info.t() | nil
  def info({:fn, _, _, _, _, %Info{} = info}), do: info
  def info(_), do: nil
end
