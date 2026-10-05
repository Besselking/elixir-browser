defmodule Browser.JS.FunctionKinds do
  @moduledoc """
  `%GeneratorFunction%`, `%AsyncFunction%` and `%AsyncGeneratorFunction%`: the constructors that are
  not globals (reach them with `Object.getPrototypeOf(function* () {}).constructor`), and the
  prototypes that generator, async and async generator functions inherit from.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Parser}

  @kinds [
    {:generator_function, "GeneratorFunction", "function*", :generator},
    {:async_function, "AsyncFunction", "async function", nil},
    {:async_generator_function, "AsyncGeneratorFunction", "async function*", :async_generator}
  ]

  def install(scope) do
    {:ok, function_ctor} = Interp.lookup_scoped(scope, "Function")

    for {key, name, keyword, instance_proto} <- @kinds do
      proto = new_object([], proto(:function))
      put_proto(key, proto)

      ctor =
        native(name, fn _, args ->
          {params, body} = Enum.split(args, -1)
          params = params |> Enum.map(&to_str/1) |> Enum.join(",")
          body = body |> Enum.map(&to_str/1) |> Enum.join()

          case Parser.parse("(#{keyword} anonymous(#{params}\n) {\n#{body}\n})") do
            {:ok, program} -> Interp.run_program(program)
            {:error, msg} -> throw_error("SyntaxError", msg)
          end
        end)

      {:obj, cid} = ctor
      store(cid, deref(cid) |> Map.put(:arity, 1.0) |> Map.put(:proto, function_ctor))
      put_const(ctor, "prototype", proto)
      configurable_only(proto, "constructor", ctor)
      put_tag(proto, name)

      if instance_proto do
        configurable_only(proto, "prototype", proto(instance_proto))
        configurable_only(proto(instance_proto), "constructor", proto)
      end
    end

    :ok
  end

  # a data property that is neither writable nor enumerable, but configurable
  defp configurable_only({:obj, id}, key, v) do
    o = deref(id)
    attrs = Map.put(Map.get(o, :attrs, %{}), key, %{w: false, c: true, e: false})
    store(id, o |> Map.put(:props, Map.put(o.props, key, v)) |> Map.put(:attrs, attrs))
  end
end
