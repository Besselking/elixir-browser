defmodule Browser.JS.Awaits do
  @moduledoc """
  Finds an `await` in a syntax tree.

  `any?/1` gives `true` when a term holds an `await`, a `yield`, a `for await` or an
  `await using`. The walk does not go into a function node, because the awaits of a nested
  function belong to that function. The walk goes into a class node, because the body of a
  class is evaluated inline.

  The CPS evaluator (`Browser.JS.Async`) uses this walk for each expression and for each
  statement of the old path. The resolver (`Browser.JS.Resolve`) uses it for
  `Info.has_await` and for the top-level awaits of a module. The `{:aw}` marks of the
  resolver come from a walk of its own, and check item C3 compares them with the evaluator.

  ## The leaf forms

  The walk does not go into a leaf form. These are the leaf forms:

  - the 2-tuples with the tags `:gen`, `:async`, `:id`, `:num`, `:str`, `:lit`, `:gref`,
    `:val` and `:bigint`,
  - the 4-tuples with the tags `:slot`, `:cslot` and `:fname`.

  This rule applies: a leaf form never holds syntax in its other elements. Today `{:id, name}`
  holds a binary, `{:val, v}` holds a JS value, and a slot holds integers and a name.
  `{:gen, f}` and `{:async, f}` hold a function, and the walk does not go into a function.
  If a new node form holds syntax, do not give it one of these tags. If you do, the walk
  does not find an `await` in it, and the evaluator runs the expression on the sync path.

  The check build (`JS_RESOLVE_CHECK=1`) compares `any?/1` with the old walk at each call
  in `Browser.JS.Async`.
  """

  @leaf2 [:gen, :async, :id, :num, :str, :lit, :gref, :val, :bigint]
  @leaf4 [:slot, :cslot, :fname]

  @doc """
  Gives `true` when `t` is a leaf form. A leaf form holds no syntax (see the moduledoc).
  You can use this guard in a function head.
  """
  defguard is_leaf_form(t)
           when is_tuple(t) and
                  ((tuple_size(t) == 2 and elem(t, 0) in @leaf2) or
                     (tuple_size(t) == 4 and elem(t, 0) in @leaf4))

  @doc "Gives `true` when `t` is a leaf form (see the moduledoc)."
  def leaf_form?(t) when is_leaf_form(t), do: true
  def leaf_form?(_t), do: false

  @doc """
  Gives `true` when the term `t` holds an `await`, a `yield`, a `for await` or an
  `await using` outside a nested function.
  """
  def any?({:await, _}), do: true
  def any?({:yield, _, _}), do: true
  def any?({:forawait, _, _, _, _}), do: true
  # A `for await` in a rewritten body has its scope as a sixth element. The loop awaits
  # also when nothing in it awaits, so the shape alone gives the answer.
  def any?({:forawait, _, _, _, _, _}), do: true
  def any?({:using, :await_using, _, _, _}), do: true
  def any?(t) when is_leaf_form(t), do: false
  def any?({:fn, _, _, _, _, _}), do: false
  def any?(t) when is_tuple(t), do: elems?(t, tuple_size(t))
  def any?([h | t]), do: any?(h) or any?(t)
  # Maps (the structs of the resolver) hold no syntax that an await can be in.
  def any?(_t), do: false

  # The walk reads the elements from the last to the first with `elem`, so it builds no
  # list. It also reads element 1, because a declaration pair `{pattern, init}` starts with
  # a pattern.
  defp elems?(_t, 0), do: false
  defp elems?(t, i), do: any?(:erlang.element(i, t)) or elems?(t, i - 1)
end
