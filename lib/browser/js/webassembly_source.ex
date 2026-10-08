defmodule Browser.JS.WebAssemblySource do
  @moduledoc false

  @source ~S"""
  function (W) {
    'use strict';
    var g = globalThis;
    var H = new WeakMap();      // JS object -> native handle
    var wrappers = new WeakMap(); // native handle -> JS object

    function defineClass(C, name) {
      Object.defineProperty(C, 'name', { value: name, configurable: true });
      Object.defineProperty(C.prototype, Symbol.toStringTag, { value: 'WebAssembly.' + name, configurable: true });
    }
    function named(C, name) {
      Object.defineProperty(C, 'name', { value: name, configurable: true });
      Object.defineProperty(C.prototype, 'name', { value: name, writable: true, configurable: true });
      return C;
    }
    var CompileError = named(class extends Error {}, 'CompileError');
    var LinkError = named(class extends Error {}, 'LinkError');
    var RuntimeError = named(class extends Error {}, 'RuntimeError');
    W.init(CompileError, LinkError, RuntimeError);

    function toU32(v, what) {
      var n = Number(v);
      if (!isFinite(n)) throw new TypeError(what + ' must be convertible to a valid number');
      n = Math.trunc(n);
      if (n < 0 || n > 4294967295) throw new TypeError(what + ' must be in the unsigned long range');
      return n;
    }
    function optU32(v, what) { return v === undefined ? undefined : toU32(v, what); }
    function need(desc, what) {
      if (desc === null || (typeof desc !== 'object' && typeof desc !== 'function'))
        throw new TypeError(what + ': Argument 0 must be a ' + what.split('.').pop().toLowerCase() + ' descriptor');
    }
    function handleOf(self, C) {
      var h = H.get(self);
      if (h === undefined) throw new TypeError('Receiver is not a ' + C);
      return h;
    }
    function adopt(self, h) { H.set(self, h); wrappers.set(h, self); return self; }

    function toBytes(src, what) {
      if (src instanceof ArrayBuffer || ArrayBuffer.isView(src)) return src;
      throw new TypeError(what + ': Argument 0 must be a buffer source');
    }

    // ── Module ───────────────────────────────────────────────
    function Module(bytes) {
      if (!new.target) throw new TypeError("WebAssembly.Module must be invoked with 'new'");
      adopt(this, W.compile(toBytes(bytes, 'WebAssembly.Module()')));
    }
    defineClass(Module, 'Module');
    function modArg(m, fn) {
      if (!(m instanceof Module)) throw new TypeError('WebAssembly.Module.' + fn + '(): Argument 0 must be a WebAssembly.Module');
      return H.get(m);
    }
    Module.imports = function imports(m) { return W.imports(modArg(m, 'imports')); };
    Module.exports = function exports(m) { return W.exports(modArg(m, 'exports')); };
    Module.customSections = function customSections(m, name) {
      var h = modArg(m, 'customSections');
      if (name === undefined) throw new TypeError('WebAssembly.Module.customSections(): Argument 1 is required');
      return W.customSections(h, String(name));
    };

    // ── Memory, Table, Global ────────────────────────────────
    function Memory(desc) {
      if (!new.target) throw new TypeError("WebAssembly.Memory must be invoked with 'new'");
      need(desc, 'WebAssembly.Memory()');
      var initial = optU32(desc.initial, 'Property \'initial\'');
      var maximum = optU32(desc.maximum, 'Property \'maximum\'');
      if (initial === undefined) throw new TypeError("WebAssembly.Memory(): Property 'initial' is required");
      adopt(this, W.memNew(initial, maximum));
    }
    defineClass(Memory, 'Memory');
    Object.defineProperty(Memory.prototype, 'buffer', {
      get: function () { return W.memBuffer(handleOf(this, 'WebAssembly.Memory')); },
      enumerable: true, configurable: true
    });
    Memory.prototype.grow = function grow(delta) {
      return W.memGrow(handleOf(this, 'WebAssembly.Memory'), toU32(delta, 'Argument 0'));
    };

    function elementName(v) {
      v = String(v);
      if (v === 'anyfunc' || v === 'funcref') return 'funcref';
      if (v === 'externref') return 'externref';
      throw new TypeError("WebAssembly.Table(): Descriptor property 'element' must be a WebAssembly reference type");
    }
    function Table(desc, init) {
      if (!new.target) throw new TypeError("WebAssembly.Table must be invoked with 'new'");
      need(desc, 'WebAssembly.Table()');
      var element = elementName(desc.element);
      var initial = optU32(desc.initial, "Property 'initial'");
      var maximum = optU32(desc.maximum, "Property 'maximum'");
      if (initial === undefined) throw new TypeError("WebAssembly.Table(): Property 'initial' is required");
      var v = arguments.length < 2 ? (element === 'externref' ? undefined : null) : init;
      adopt(this, W.tblNew(element, initial, maximum, v));
    }
    defineClass(Table, 'Table');
    Object.defineProperty(Table.prototype, 'length', {
      get: function () { return W.tblSize(handleOf(this, 'WebAssembly.Table')); },
      enumerable: true, configurable: true
    });
    Table.prototype.get = function get(i) { return W.tblGet(handleOf(this, 'WebAssembly.Table'), toU32(i, 'Argument 0')); };
    Table.prototype.set = function set(i, v) {
      var h = handleOf(this, 'WebAssembly.Table');
      var idx = toU32(i, 'Argument 0');
      return arguments.length < 2 ? W.tblSet(h, idx) : W.tblSet(h, idx, v);
    };
    Table.prototype.grow = function grow(delta, v) {
      var h = handleOf(this, 'WebAssembly.Table');
      var d = toU32(delta, 'Argument 0');
      return arguments.length < 2 ? W.tblGrow(h, d) : W.tblGrow(h, d, v);
    };

    function Global(desc, v) {
      if (!new.target) throw new TypeError("WebAssembly.Global must be invoked with 'new'");
      need(desc, 'WebAssembly.Global()');
      var type = String(desc.value);
      if (['i32', 'i64', 'f32', 'f64', 'externref', 'anyfunc', 'funcref'].indexOf(type) < 0)
        throw new TypeError("WebAssembly.Global(): Descriptor property 'value' must be a WebAssembly type");
      adopt(this, W.globNew(type === 'funcref' ? 'anyfunc' : type, !!desc.mutable, v));
    }
    defineClass(Global, 'Global');
    Object.defineProperty(Global.prototype, 'value', {
      get: function () { return W.globGet(handleOf(this, 'WebAssembly.Global')); },
      set: function (v) { W.globSet(handleOf(this, 'WebAssembly.Global'), v); },
      enumerable: true, configurable: true
    });
    Global.prototype.valueOf = function valueOf() { return W.globGet(handleOf(this, 'WebAssembly.Global')); };

    function wrap(kind, h) {
      var w = wrappers.get(h);
      if (w) return w;
      var C = kind === 'memory' ? Memory : kind === 'table' ? Table : Global;
      w = Object.create(C.prototype);
      return adopt(w, h);
    }

    // ── Instance ─────────────────────────────────────────────
    function build(mod, imports) {
      var h = H.get(mod);
      var wanted = W.imports(h);
      if (imports !== undefined && (imports === null || typeof imports !== 'object' && typeof imports !== 'function'))
        throw new TypeError('WebAssembly.Instance(): Argument 1 must be an object');
      if (wanted.length > 0 && imports === undefined)
        throw new TypeError('WebAssembly.Instance(): Imports argument must be present and must be an object');
      var entries = W.instantiate(h, function (module, name, kind) {
        var m = imports[module];
        if (m === null || (typeof m !== 'object' && typeof m !== 'function'))
          throw new TypeError('WebAssembly.Instance(): Import #0 "' + module + '": module is not an object or function');
        var v = m[name];
        if (v !== null && typeof v === 'object' && H.has(v)) return H.get(v);
        return v;
      });
      var ex = Object.create(null);
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        ex[e[0]] = e[1] === 'function' ? e[2] : wrap(e[1], e[2]);
      }
      return Object.freeze(ex);
    }
    var exportsOf = new WeakMap();
    function Instance(module, imports) {
      if (!new.target) throw new TypeError("WebAssembly.Instance must be invoked with 'new'");
      if (!(module instanceof Module)) throw new TypeError('WebAssembly.Instance(): Argument 0 must be a WebAssembly.Module');
      exportsOf.set(this, build(module, imports));
    }
    defineClass(Instance, 'Instance');
    Object.defineProperty(Instance.prototype, 'exports', {
      get: function () {
        var e = exportsOf.get(this);
        if (e === undefined) throw new TypeError('Receiver is not a WebAssembly.Instance');
        return e;
      },
      enumerable: true, configurable: true
    });

    // ── functions ────────────────────────────────────────────
    function validate(bytes) { return W.validate(toBytes(bytes, 'WebAssembly.validate()')); }
    function compile(bytes) {
      return new Promise(function (resolve, reject) {
        try { resolve(new Module(bytes)); } catch (e) { reject(e); }
      });
    }
    function instantiate(source, imports) {
      return new Promise(function (resolve, reject) {
        try {
          if (source instanceof Module) {
            var inst = Object.create(Instance.prototype);
            exportsOf.set(inst, build(source, imports));
            resolve(inst);
          } else {
            var module = new Module(source);
            var instance = Object.create(Instance.prototype);
            exportsOf.set(instance, build(module, imports));
            resolve({ module: module, instance: instance });
          }
        } catch (e) { reject(e); }
      });
    }
    function bytesOfResponse(source, what) {
      return Promise.resolve(source).then(function (r) {
        var type = r && r.headers && r.headers.get && r.headers.get('content-type');
        if (!type || String(type).split(';')[0].trim().toLowerCase() !== 'application/wasm')
          throw new TypeError('WebAssembly.' + what + ': Incorrect response MIME type. Expected \'application/wasm\'.');
        if (!r.ok) throw new TypeError('WebAssembly.' + what + ': HTTP status code is not ok');
        return r.arrayBuffer();
      });
    }
    function compileStreaming(source) {
      return bytesOfResponse(source, 'compileStreaming()').then(function (b) { return new Module(b); });
    }
    function instantiateStreaming(source, imports) {
      return bytesOfResponse(source, 'instantiateStreaming()').then(function (b) { return instantiate(b, imports); });
    }

    var WebAssembly = {};
    var api = {
      Module: Module, Instance: Instance, Memory: Memory, Table: Table, Global: Global,
      CompileError: CompileError, LinkError: LinkError, RuntimeError: RuntimeError,
      validate: validate, compile: compile, instantiate: instantiate,
      compileStreaming: compileStreaming, instantiateStreaming: instantiateStreaming
    };
    for (var k in api) {
      Object.defineProperty(WebAssembly, k, { value: api[k], writable: true, configurable: true, enumerable: false });
    }
    Object.defineProperty(WebAssembly, Symbol.toStringTag, { value: 'WebAssembly', configurable: true });
    Object.defineProperty(g, 'WebAssembly', { value: WebAssembly, writable: true, configurable: true, enumerable: false });
  }
  """

  @doc "The JavaScript of the `WebAssembly` object: a function of the natives and the global object."
  def source, do: @source
end
