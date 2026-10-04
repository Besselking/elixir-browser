defmodule Browser.JS.Prelude do
  @moduledoc """
  Built-in functions written in JavaScript, for the ones whose spec text is mostly a sequence
  of awaits and observable property reads (`Array.fromAsync`, `Promise.allKeyed`, ...). Each is
  a native stub that parses and evaluates its source the first time it is called, so a page
  that never uses it pays nothing. The stub has the right `name` and `length` and, like any
  built-in method, is not a constructor.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Parser}

  @doc "A native `name` with `length` `arity` that runs the function expression `source`."
  def lazy(name, arity, source) do
    key = {:js_prelude, name}

    f =
      native(name, fn this, args ->
        impl =
          case :erlang.get(key) do
            :undefined ->
              {:ok, {:program, [{:expr, expr}]}} = Parser.parse("(" <> source <> ")")
              impl = Interp.ev(expr, Interp.global())
              :erlang.put(key, impl)
              impl

            impl ->
              impl
          end

        call(impl, this, args)
      end)

    {:obj, id} = f
    store(id, Map.put(deref(id), :arity, arity * 1.0))
    f
  end

  @from_async """
  async function (asyncItems) {
    var mapfn = arguments[1], thisArg = arguments[2], C = this;
    var mapping = mapfn !== undefined;
    if (mapping && typeof mapfn !== 'function') throw new TypeError('Array.fromAsync: mapper is not callable');
    var method = function (o, sym) {
      var m = o[sym];
      if (m === undefined || m === null) return undefined;
      if (typeof m !== 'function') throw new TypeError('iterator method is not callable');
      return m;
    };
    var close = async function (it) {
      var r = it.return;
      if (r !== undefined && r !== null) await r.call(it);
    };
    var define = function (A, k, v) {
      Object.defineProperty(A, k, { value: v, writable: true, enumerable: true, configurable: true });
    };
    var usingAsync = method(asyncItems, Symbol.asyncIterator);
    var usingSync = usingAsync === undefined ? method(asyncItems, Symbol.iterator) : undefined;
    var A, k = 0;
    if (usingAsync !== undefined || usingSync !== undefined) {
      A = isCtor(C) ? new C() : [];
      var isAsync = usingAsync !== undefined;
      var it = (isAsync ? usingAsync : usingSync).call(asyncItems);
      if (Object(it) !== it) throw new TypeError('iterator is not an object');
      var next = it.next;
      while (true) {
        var r = next.call(it);
        if (isAsync) r = await r;
        if (Object(r) !== r) throw new TypeError('iterator result is not an object');
        if (r.done) { A.length = k; return A; }
        var value = r.value;
        if (!isAsync) {
          try { value = await value; } catch (e) { try { it.return && it.return(); } catch (_) {} throw e; }
        }
        try {
          if (mapping) { value = mapfn.call(thisArg, value, k); value = await value; }
          define(A, k, value);
        } catch (e) {
          try { await close(it); } catch (_) {}
          throw e;
        }
        k++;
      }
    }
    var arrayLike = Object(asyncItems);
    var len = Math.min(Math.max(Math.trunc(Number(arrayLike.length)) || 0, 0), 9007199254740991);
    A = isCtor(C) ? new C(len) : new Array(len);
    for (; k < len; k++) {
      var kValue = await arrayLike[k];
      if (mapping) kValue = await mapfn.call(thisArg, kValue, k);
      define(A, k, kValue);
    }
    A.length = len;
    return A;
  }
  """

  def from_async,
    do:
      lazy(
        "fromAsync",
        1,
        "function(){ var isCtor = function(f){ try { Reflect.construct(Object, [], f); return true; } catch (e) { return false; } }; return (#{@from_async}); }()"
      )

  @capability """
  var capability = function (C) {
    var resolve, reject, called = false;
    var promise = new C(function (res, rej) {
      if (resolve !== undefined || reject !== undefined) throw new TypeError('Promise executor has already been invoked');
      resolve = res; reject = rej;
    });
    if (typeof resolve !== 'function' || typeof reject !== 'function') throw new TypeError('Promise resolve or reject function is not callable');
    return { promise: promise, resolve: resolve, reject: reject };
  };
  var keyed = function (C, promises, settled) {
    var cap = capability(C);
    var promiseResolve;
    try {
      promiseResolve = C.resolve;
      if (typeof promiseResolve !== 'function') throw new TypeError('Promise resolve is not a function');
    } catch (e) { cap.reject(e); return cap.promise; }
    try {
      if (Object(promises) !== promises) throw new TypeError('Promise.allKeyed expects an object');
      var allKeys = Reflect.ownKeys(promises);
      var keys = [], values = [], remaining = 1;
      var finish = function () {
        var obj = Object.create(null);
        for (var i = 0; i < keys.length; i++)
          Object.defineProperty(obj, keys[i], { value: values[i], writable: true, enumerable: true, configurable: true });
        cap.resolve(obj);
      };
      var elements = function (index) {
        var called = false;
        var settle = function (v) {
          if (called) return;
          called = true;
          values[index] = v;
          if (--remaining === 0) finish();
        };
        return [
          x => { settle(settled ? { status: 'fulfilled', value: x } : x); return undefined; },
          x => { settle({ status: 'rejected', reason: x }); return undefined; }
        ];
      };
      for (var n = 0; n < allKeys.length; n++) {
        var key = allKeys[n];
        var desc = Reflect.getOwnPropertyDescriptor(promises, key);
        if (desc !== undefined && desc.enumerable) {
          var value = promises[key];
          var next = promiseResolve.call(C, value);
          var index = keys.length;
          keys.push(key); values.push(undefined);
          remaining++;
          var pair = elements(index);
          next.then(pair[0], settled ? pair[1] : cap.reject);
        }
      }
      if (--remaining === 0) finish();
    } catch (e) { cap.reject(e); }
    return cap.promise;
  };
  """

  def all_keyed,
    do:
      lazy(
        "allKeyed",
        1,
        "function(){ #{@capability} return function (promises) { return keyed(this, promises, false); }; }()"
      )

  def all_settled_keyed,
    do:
      lazy(
        "allSettledKeyed",
        1,
        "function(){ #{@capability} return function (promises) { return keyed(this, promises, true); }; }()"
      )
end
