// Range, Selection and document.execCommand: what a contenteditable needs. Loaded the first time a
// page asks for the selection, a range or a command (see Browser.JS.Editing).
//
// Offsets count code points, like the strings of this runtime. A position the session is told
// about (`__ed.report`) is always a text node and an offset into it where there is text, so the
// layout can turn it into a place on the screen.
(function (g) {
  "use strict";

  var doc = g.document;
  var DP = Object.getPrototypeOf(doc);
  var NP = g.Node.prototype;
  var ELEMENT = 1, TEXT = 3, COMMENT = 8, DOCUMENT = 9, FRAGMENT = 11;
  var NBSP = " ";

  function hide(obj, name, value) {
    Object.defineProperty(obj, name, { value: value, writable: true, configurable: true, enumerable: false });
  }
  function getter(obj, name, fn) {
    Object.defineProperty(obj, name, { get: fn, configurable: true, enumerable: true });
  }
  function words(s) {
    var o = {};
    s.split(" ").forEach(function (w) { o[w] = true; });
    return o;
  }

  // ── tree helpers ──────────────────────────────────────────

  var BLOCK = words("ADDRESS ARTICLE ASIDE BLOCKQUOTE BODY CAPTION DD DETAILS DIV DL DT FIELDSET FIGCAPTION FIGURE FOOTER FORM H1 H2 H3 H4 H5 H6 HEADER HR HTML LI MAIN NAV OL P PRE SECTION TABLE TBODY TFOOT THEAD TR TD TH UL");
  // blocks that hold text (and inline elements) themselves
  var TEXTBLOCK = words("ADDRESS ARTICLE ASIDE BLOCKQUOTE CAPTION DD DIV DT FIELDSET FIGCAPTION FOOTER H1 H2 H3 H4 H5 H6 HEADER LI MAIN NAV P PRE SECTION TD TH");
  var LEAF = words("BR IMG HR INPUT");

  function isText(n) { return !!n && n.nodeType === TEXT; }
  function isEl(n) { return !!n && n.nodeType === ELEMENT; }
  function isCD(n) { return !!n && (n.nodeType === TEXT || n.nodeType === COMMENT); }
  function isBlockEl(n) { return isEl(n) && BLOCK[n.nodeName] === true; }
  function len(n) { return isCD(n) ? n.data.length : n.childNodes.length; }
  function kids(n) { return n.childNodes; }
  function idx(n) { return Array.prototype.indexOf.call(n.parentNode.childNodes, n); }
  function contains(a, b) { return a === b || a.contains(b); }
  function rootOf(n) { while (n.parentNode) n = n.parentNode; return n; }
  function childOf(anc, n) { while (n.parentNode !== anc) n = n.parentNode; return n; }
  function dom(name, msg) { return new g.DOMException(msg, name); }

  // the order of two boundary points: -1, 0 or 1
  function cmp(an, ao, bn, bo) {
    if (an === bn) return ao === bo ? 0 : ao < bo ? -1 : 1;
    var pos = an.compareDocumentPosition(bn);
    if (pos & 4) {
      if (pos & 16) return idx(childOf(an, bn)) < ao ? 1 : -1;
      return -1;
    }
    if (pos & 8) return idx(childOf(bn, an)) < bo ? -1 : 1;
    return 1;
  }

  function walkText(n, fn) {
    if (isText(n)) { fn(n); return; }
    var ks = n.childNodes;
    for (var i = 0; i < ks.length; i++) walkText(ks[i], fn);
  }
  function textNodes(n) {
    var out = [];
    walkText(n, function (t) { out.push(t); });
    return out;
  }

  // ── live ranges ───────────────────────────────────────────
  // A range follows the changes made to the tree through the methods below, which are wrapped
  // once the first range exists. (Assigning textContent, innerHTML and the like replaces what
  // the boundaries point into; a range left in a node that has left the document is dropped
  // by the selection.)

  var live = [];

  function Range() {
    this._sc = doc; this._so = 0; this._ec = doc; this._eo = 0;
    live.push(this);
    if (live.length > 400) live.shift();
  }
  var RP = Range.prototype;
  getter(RP, "startContainer", function () { return this._sc; });
  getter(RP, "startOffset", function () { return this._so; });
  getter(RP, "endContainer", function () { return this._ec; });
  getter(RP, "endOffset", function () { return this._eo; });
  getter(RP, "collapsed", function () { return this._sc === this._ec && this._so === this._eo; });
  getter(RP, "commonAncestorContainer", function () {
    var n = this._sc;
    while (n && !contains(n, this._ec)) n = n.parentNode;
    return n || doc;
  });
  ["START_TO_START", "START_TO_END", "END_TO_END", "END_TO_START"].forEach(function (k, i) {
    Object.defineProperty(Range, k, { value: i });
    Object.defineProperty(RP, k, { value: i });
  });

  function check(n, o) {
    if (!n || typeof n.nodeType !== "number") throw new TypeError("The node provided is not a Node.");
    if (n.nodeType === 10) throw dom("InvalidNodeTypeError", "The node is a doctype.");
    if (o > len(n) || o < 0) throw dom("IndexSizeError", "The offset " + o + " is larger than the node's length (" + len(n) + ").");
  }

  RP.setStart = function (n, o) {
    o = o >>> 0; check(n, o);
    this._sc = n; this._so = o;
    if (rootOf(n) !== rootOf(this._ec) || cmp(n, o, this._ec, this._eo) > 0) { this._ec = n; this._eo = o; }
  };
  RP.setEnd = function (n, o) {
    o = o >>> 0; check(n, o);
    this._ec = n; this._eo = o;
    if (rootOf(n) !== rootOf(this._sc) || cmp(n, o, this._sc, this._so) < 0) { this._sc = n; this._so = o; }
  };
  RP.setStartBefore = function (n) { this.setStart(n.parentNode, idx(n)); };
  RP.setStartAfter = function (n) { this.setStart(n.parentNode, idx(n) + 1); };
  RP.setEndBefore = function (n) { this.setEnd(n.parentNode, idx(n)); };
  RP.setEndAfter = function (n) { this.setEnd(n.parentNode, idx(n) + 1); };
  RP.collapse = function (toStart) {
    if (toStart) { this._ec = this._sc; this._eo = this._so; } else { this._sc = this._ec; this._so = this._eo; }
  };
  RP.selectNode = function (n) {
    var p = n.parentNode;
    if (!p) throw dom("InvalidNodeTypeError", "The node has no parent.");
    var i = idx(n);
    this._sc = p; this._ec = p; this._so = i; this._eo = i + 1;
  };
  RP.selectNodeContents = function (n) {
    check(n, 0);
    this._sc = n; this._ec = n; this._so = 0; this._eo = len(n);
  };
  RP.cloneRange = function () {
    var r = new Range();
    r._sc = this._sc; r._so = this._so; r._ec = this._ec; r._eo = this._eo;
    return r;
  };
  RP.detach = function () {};
  RP.compareBoundaryPoints = function (how, other) {
    var a, ao, b, bo;
    if (how === 0) { a = this._sc; ao = this._so; b = other._sc; bo = other._so; }
    else if (how === 1) { a = this._ec; ao = this._eo; b = other._sc; bo = other._so; }
    else if (how === 2) { a = this._ec; ao = this._eo; b = other._ec; bo = other._eo; }
    else if (how === 3) { a = this._sc; ao = this._so; b = other._ec; bo = other._eo; }
    else throw dom("NotSupportedError", "The comparison method provided must be one of START_TO_START, START_TO_END, END_TO_END or END_TO_START.");
    return cmp(a, ao, b, bo);
  };
  RP.comparePoint = function (n, o) {
    if (rootOf(n) !== rootOf(this._sc)) throw dom("WrongDocumentError", "The node is not in the same tree as the range.");
    check(n, o);
    if (cmp(n, o, this._sc, this._so) < 0) return -1;
    if (cmp(n, o, this._ec, this._eo) > 0) return 1;
    return 0;
  };
  RP.isPointInRange = function (n, o) {
    if (rootOf(n) !== rootOf(this._sc)) return false;
    check(n, o);
    return cmp(n, o, this._sc, this._so) >= 0 && cmp(n, o, this._ec, this._eo) <= 0;
  };
  RP.intersectsNode = function (n) {
    if (rootOf(n) !== rootOf(this._sc)) return false;
    var p = n.parentNode;
    if (!p) return true;
    var i = idx(n);
    return cmp(p, i, this._ec, this._eo) < 0 && cmp(p, i + 1, this._sc, this._so) > 0;
  };

  function fullyContained(c, r) {
    return cmp(c, 0, r._sc, r._so) > 0 && cmp(c, len(c), r._ec, r._eo) < 0;
  }
  // the top-most nodes inside the range that it holds completely, in tree order
  function containedNodes(r) {
    var out = [];
    (function collect(n) {
      var ks = Array.prototype.slice.call(n.childNodes);
      for (var i = 0; i < ks.length; i++) {
        var c = ks[i];
        if (fullyContained(c, r)) out.push(c);
        else if (contains(c, r._sc) || contains(c, r._ec)) collect(c);
      }
    })(r.commonAncestorContainer);
    return out;
  }

  RP.toString = function () {
    if (this._sc === this._ec && isText(this._sc)) return this._sc.data.slice(this._so, this._eo);
    var s = "", self = this;
    if (isText(this._sc)) s += this._sc.data.slice(this._so);
    walkText(this.commonAncestorContainer, function (t) {
      if (t === self._sc || t === self._ec) return;
      if (cmp(t, 0, self._sc, self._so) >= 0 && cmp(t, t.data.length, self._ec, self._eo) <= 0) s += t.data;
    });
    if (isText(this._ec) && this._ec !== this._sc) s += this._ec.data.slice(0, this._eo);
    return s;
  };

  // removes (extract) or copies (clone) what the range holds, as a fragment
  function pull(r, remove) {
    var frag = doc.createDocumentFragment();
    if (r.collapsed) return frag;
    var sc = r._sc, so = r._so, ec = r._ec, eo = r._eo;
    if (sc === ec && isCD(sc)) {
      var c = sc.cloneNode(false);
      c.data = sc.data.slice(so, eo);
      frag.appendChild(c);
      if (remove) sc.deleteData(so, eo - so);
      return frag;
    }
    var C = r.commonAncestorContainer;
    var ks = Array.prototype.slice.call(C.childNodes);
    var first = contains(sc, ec) ? null : childOf(C, sc);
    var last = contains(ec, sc) ? null : childOf(C, ec);
    var fi = first ? ks.indexOf(first) + 1 : so;
    var li = last ? ks.indexOf(last) : eo;
    var middle = ks.slice(fi, li);
    var newNode, newOff;
    if (contains(sc, ec)) { newNode = sc; newOff = so; }
    else {
      var ref = sc;
      while (ref.parentNode && !contains(ref.parentNode, ec)) ref = ref.parentNode;
      newNode = ref.parentNode; newOff = idx(ref) + 1;
    }
    if (first) {
      if (isCD(first)) {
        var fc = first.cloneNode(false);
        fc.data = first.data.slice(so);
        frag.appendChild(fc);
        if (remove) first.deleteData(so, first.data.length - so);
      } else {
        var fcl = first.cloneNode(false);
        frag.appendChild(fcl);
        var sub = new Range();
        sub._sc = sc; sub._so = so; sub._ec = first; sub._eo = len(first);
        fcl.appendChild(pull(sub, remove));
        dropLive(sub);
      }
    }
    middle.forEach(function (n) {
      if (remove) frag.appendChild(n); else frag.appendChild(n.cloneNode(true));
    });
    if (last) {
      if (isCD(last)) {
        var lc = last.cloneNode(false);
        lc.data = last.data.slice(0, eo);
        frag.appendChild(lc);
        if (remove) last.deleteData(0, eo);
      } else {
        var lcl = last.cloneNode(false);
        frag.appendChild(lcl);
        var sub2 = new Range();
        sub2._sc = last; sub2._so = 0; sub2._ec = ec; sub2._eo = eo;
        lcl.appendChild(pull(sub2, remove));
        dropLive(sub2);
      }
    }
    if (remove) { r._sc = newNode; r._ec = newNode; r._so = newOff; r._eo = newOff; }
    return frag;
  }
  function dropLive(r) {
    var i = live.indexOf(r);
    if (i >= 0) live.splice(i, 1);
  }

  RP.extractContents = function () { return pull(this, true); };
  RP.cloneContents = function () { return pull(this, false); };
  RP.deleteContents = function () {
    if (this.collapsed) return;
    var sc = this._sc, so = this._so, ec = this._ec, eo = this._eo;
    if (sc === ec && isCD(sc)) { sc.deleteData(so, eo - so); return; }
    var gone = containedNodes(this);
    var newNode, newOff;
    if (contains(sc, ec)) { newNode = sc; newOff = so; }
    else {
      var ref = sc;
      while (ref.parentNode && !contains(ref.parentNode, ec)) ref = ref.parentNode;
      newNode = ref.parentNode; newOff = idx(ref) + 1;
    }
    if (isCD(sc)) sc.deleteData(so, sc.data.length - so);
    gone.forEach(function (n) { if (n.parentNode) n.parentNode.removeChild(n); });
    if (isCD(ec)) ec.deleteData(0, eo);
    this._sc = newNode; this._ec = newNode; this._so = newOff; this._eo = newOff;
  };
  RP.insertNode = function (node) {
    var sc = this._sc, ref, parent;
    if (isText(sc)) { ref = sc.splitText(this._so); parent = sc.parentNode; }
    else { ref = sc.childNodes[this._so] || null; parent = sc; }
    if (ref === node) ref = node.nextSibling;
    var newOff = ref ? idx(ref) : len(parent);
    newOff += node.nodeType === FRAGMENT ? node.childNodes.length : 1;
    parent.insertBefore(node, ref);
    if (this.collapsed) { this._ec = parent; this._eo = newOff; }
  };
  RP.surroundContents = function (parent) {
    var frag = this.extractContents();
    while (parent.firstChild) parent.removeChild(parent.firstChild);
    this.insertNode(parent);
    parent.appendChild(frag);
    this.selectNode(parent);
  };
  RP.createContextualFragment = function (html) {
    var t = doc.createElement("template");
    t.innerHTML = html;
    var f = doc.createDocumentFragment();
    while (t.firstChild) f.appendChild(t.firstChild);
    return f;
  };
  RP.getBoundingClientRect = function () {
    var n = this._sc;
    if (!isEl(n)) n = n.parentElement;
    return n && n.getBoundingClientRect ? n.getBoundingClientRect() : { x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 };
  };
  RP.getClientRects = function () { return [this.getBoundingClientRect()]; };

  // ── keeping ranges up to date ─────────────────────────────

  function adjustRemove(node) {
    var p = node.parentNode;
    if (!p) return;
    var i = idx(node);
    live.forEach(function (r) {
      if (contains(node, r._sc)) { r._sc = p; r._so = i; }
      else if (r._sc === p && r._so > i) r._so--;
      if (contains(node, r._ec)) { r._ec = p; r._eo = i; }
      else if (r._ec === p && r._eo > i) r._eo--;
    });
  }
  function adjustInsert(parent, i, count) {
    live.forEach(function (r) {
      if (r._sc === parent && r._so > i) r._so += count;
      if (r._ec === parent && r._eo > i) r._eo += count;
    });
  }
  function adjustSplit(node, off, fresh) {
    var p = node.parentNode, i = p ? idx(node) : -1;
    live.forEach(function (r) {
      if (r._sc === node && r._so > off) { r._sc = fresh; r._so -= off; }
      if (r._ec === node && r._eo > off) { r._ec = fresh; r._eo -= off; }
      if (p && r._sc === p && r._so === i + 1) r._so++;
      if (p && r._ec === p && r._eo === i + 1) r._eo++;
    });
  }
  function adjustData(node, off, count, added) {
    live.forEach(function (r) {
      if (r._sc === node) { if (r._so > off && r._so <= off + count) r._so = off; else if (r._so > off + count) r._so += added - count; }
      if (r._ec === node) { if (r._eo > off && r._eo <= off + count) r._eo = off; else if (r._eo > off + count) r._eo += added - count; }
    });
  }

  function wrap(proto, name, make) {
    var orig = proto[name];
    hide(proto, name, make(orig));
  }
  function asNode(x) { return typeof x === "object" && x !== null && typeof x.nodeType === "number" ? x : doc.createTextNode(String(x)); }

  wrap(NP, "removeChild", function (orig) {
    return function (c) { if (live.length && c && c.parentNode === this) adjustRemove(c); return orig.call(this, c); };
  });
  wrap(NP, "remove", function (orig) {
    return function () { if (live.length && this.parentNode) adjustRemove(this); return orig.call(this); };
  });
  wrap(NP, "insertBefore", function (orig) {
    return function (n, ref) {
      if (!live.length) return orig.call(this, n, ref);
      if (n.nodeType !== FRAGMENT && n.parentNode) n.parentNode.removeChild(n);
      var count = n.nodeType === FRAGMENT ? n.childNodes.length : 1;
      var i = ref ? idx(ref) : len(this);
      var r = orig.call(this, n, ref);
      adjustInsert(this, i, count);
      return r;
    };
  });
  wrap(NP, "appendChild", function (orig) {
    return function (n) { return this.insertBefore(n, null); };
  });
  wrap(NP, "replaceChild", function (orig) {
    return function (n, old) {
      var ref = old.nextSibling;
      this.removeChild(old);
      this.insertBefore(n, ref === n ? n.nextSibling : ref);
      return old;
    };
  });
  wrap(NP, "append", function (orig) {
    return function () { for (var i = 0; i < arguments.length; i++) this.appendChild(asNode(arguments[i])); };
  });
  wrap(NP, "prepend", function (orig) {
    return function () {
      var first = this.firstChild;
      for (var i = 0; i < arguments.length; i++) this.insertBefore(asNode(arguments[i]), first);
    };
  });
  wrap(NP, "before", function (orig) {
    return function () {
      var p = this.parentNode;
      if (!p) return;
      for (var i = 0; i < arguments.length; i++) p.insertBefore(asNode(arguments[i]), this);
    };
  });
  wrap(NP, "after", function (orig) {
    return function () {
      var p = this.parentNode;
      if (!p) return;
      var ref = this.nextSibling;
      for (var i = 0; i < arguments.length; i++) p.insertBefore(asNode(arguments[i]), ref);
    };
  });
  wrap(NP, "replaceWith", function (orig) {
    return function () {
      var p = this.parentNode;
      if (!p) return;
      var ref = this.nextSibling;
      for (var i = 0; i < arguments.length; i++) { if (arguments[i] === ref) ref = ref.nextSibling; }
      p.removeChild(this);
      for (var j = 0; j < arguments.length; j++) p.insertBefore(asNode(arguments[j]), ref);
    };
  });
  wrap(NP, "replaceChildren", function (orig) {
    return function () {
      while (this.firstChild) this.removeChild(this.firstChild);
      for (var i = 0; i < arguments.length; i++) this.appendChild(asNode(arguments[i]));
    };
  });
  wrap(NP, "splitText", function (orig) {
    return function (off) {
      var fresh = orig.call(this, off);
      if (live.length) adjustSplit(this, off, fresh);
      return fresh;
    };
  });
  wrap(NP, "insertData", function (orig) {
    return function (off, s) { orig.call(this, off, s); if (live.length) adjustData(this, off, 0, String(s).length); };
  });
  wrap(NP, "deleteData", function (orig) {
    return function (off, count) {
      var n = Math.min(count, this.data.length - off);
      orig.call(this, off, count);
      if (live.length) adjustData(this, off, n, 0);
    };
  });
  wrap(NP, "replaceData", function (orig) {
    return function (off, count, s) {
      var n = Math.min(count, this.data.length - off);
      orig.call(this, off, count, s);
      if (live.length) adjustData(this, off, n, String(s).length);
    };
  });
  wrap(NP, "normalize", function (orig) {
    return function () {
      // merge the text nodes here, keeping ranges where they were
      (function visit(n) {
        var ks = Array.prototype.slice.call(n.childNodes);
        for (var i = 0; i < ks.length; i++) {
          var c = ks[i];
          if (isText(c)) {
            if (c.data === "") { n.removeChild(c); continue; }
            while (c.nextSibling && isText(c.nextSibling)) {
              var nx = c.nextSibling, at = c.data.length;
              live.forEach(function (r) {
                if (r._sc === nx) { r._sc = c; r._so += at; }
                else if (r._sc === n && r._so === idx(nx)) { r._sc = c; r._so = at; }
                if (r._ec === nx) { r._ec = c; r._eo += at; }
                else if (r._ec === n && r._eo === idx(nx)) { r._ec = c; r._eo = at; }
              });
              c.appendData(nx.data);
              n.removeChild(nx);
              ks = Array.prototype.slice.call(n.childNodes);
            }
          } else if (isEl(c)) visit(c);
        }
      })(this);
    };
  });

  // ── Selection ─────────────────────────────────────────────

  function Selection() {}
  var SP = Selection.prototype;
  var selection = Object.create(SP);
  selection._range = null;
  selection._backward = false;
  selection._pending = false;

  function valid(s) {
    var r = s._range;
    if (r && (rootOf(r._sc) !== doc || rootOf(r._ec) !== doc)) { s._range = null; return false; }
    return !!r;
  }
  getter(SP, "rangeCount", function () { return valid(this) ? 1 : 0; });
  getter(SP, "isCollapsed", function () { return !valid(this) || this._range.collapsed; });
  getter(SP, "type", function () { return !valid(this) ? "None" : this._range.collapsed ? "Caret" : "Range"; });
  getter(SP, "direction", function () { return !valid(this) || this._range.collapsed ? "none" : this._backward ? "backward" : "forward"; });
  getter(SP, "anchorNode", function () { return valid(this) ? (this._backward ? this._range._ec : this._range._sc) : null; });
  getter(SP, "anchorOffset", function () { return valid(this) ? (this._backward ? this._range._eo : this._range._so) : 0; });
  getter(SP, "focusNode", function () { return valid(this) ? (this._backward ? this._range._sc : this._range._ec) : null; });
  getter(SP, "focusOffset", function () { return valid(this) ? (this._backward ? this._range._so : this._range._eo) : 0; });
  getter(SP, "baseNode", function () { return this.anchorNode; });
  getter(SP, "baseOffset", function () { return this.anchorOffset; });
  getter(SP, "extentNode", function () { return this.focusNode; });
  getter(SP, "extentOffset", function () { return this.focusOffset; });

  function own(s) {
    if (!s._range) { s._range = new Range(); }
    return s._range;
  }
  function setRange(s, an, ao, fn, fo) {
    var r = own(s);
    var back = cmp(an, ao, fn, fo) > 0;
    s._backward = back;
    r._sc = back ? fn : an; r._so = back ? fo : ao;
    r._ec = back ? an : fn; r._eo = back ? ao : fo;
    changed();
  }
  SP.getRangeAt = function (i) {
    if (!valid(this) || i !== 0) throw dom("IndexSizeError", "" + i + " is not a valid index.");
    return this._range;
  };
  SP.addRange = function (r) {
    if (valid(this) || rootOf(r._sc) !== doc) return;
    this._range = r;
    this._backward = false;
    changed();
  };
  SP.removeRange = function (r) {
    if (this._range === r) { this._range = null; changed(); }
    else throw dom("NotFoundError", "The given range isn't in the selection.");
  };
  SP.removeAllRanges = function () { if (this._range) { this._range = null; changed(); } };
  SP.empty = SP.removeAllRanges;
  SP.collapse = function (n, o) {
    if (n === null || n === undefined) { this.removeAllRanges(); return; }
    o = (o || 0) >>> 0; check(n, o);
    if (rootOf(n) !== doc) return;
    setRange(this, n, o, n, o);
  };
  SP.setPosition = SP.collapse;
  SP.collapseToStart = function () {
    if (!valid(this)) throw dom("InvalidStateError", "There is no selection to collapse.");
    var r = this._range;
    setRange(this, r._sc, r._so, r._sc, r._so);
  };
  SP.collapseToEnd = function () {
    if (!valid(this)) throw dom("InvalidStateError", "There is no selection to collapse.");
    var r = this._range;
    setRange(this, r._ec, r._eo, r._ec, r._eo);
  };
  SP.extend = function (n, o) {
    if (!valid(this)) throw dom("InvalidStateError", "There is no selection to extend.");
    o = (o || 0) >>> 0; check(n, o);
    var an = this.anchorNode, ao = this.anchorOffset;
    setRange(this, an, ao, n, o);
  };
  SP.setBaseAndExtent = function (an, ao, fn, fo) {
    check(an, ao >>> 0); check(fn, fo >>> 0);
    setRange(this, an, ao >>> 0, fn, fo >>> 0);
  };
  SP.selectAllChildren = function (n) {
    check(n, 0);
    setRange(this, n, 0, n, len(n));
  };
  SP.containsNode = function (n, partial) {
    if (!valid(this) || rootOf(n) !== doc) return false;
    var r = this._range, p = n.parentNode, i = p ? idx(n) : 0;
    var startsBefore = cmp(p || n, p ? i : 0, r._sc, r._so) < 0, endsAfter = cmp(p || n, p ? i + 1 : len(n), r._ec, r._eo) > 0;
    if (partial) return cmp(p || n, p ? i : 0, r._ec, r._eo) < 0 && cmp(p || n, p ? i + 1 : len(n), r._sc, r._so) > 0;
    return !startsBefore && !endsAfter;
  };
  SP.deleteFromDocument = function () {
    if (!valid(this)) return;
    this._range.deleteContents();
    changed();
  };
  SP.toString = function () { return valid(this) ? this._range.toString() : ""; };
  SP.getComposedRanges = function () { return valid(this) ? [this._range] : []; };

  // ── telling the page and the window ───────────────────────

  // the position `(node, offset)` as a text node and an offset into it where the point is in or
  // beside text, else the element and child index it is at
  function firstLeaf(n) {
    if (isText(n)) return n.data.length ? n : null;
    if (!isEl(n)) return null;
    if (LEAF[n.nodeName]) return n;
    var ks = n.childNodes;
    for (var i = 0; i < ks.length; i++) { var l = firstLeaf(ks[i]); if (l) return l; }
    return null;
  }
  function lastLeaf(n) {
    if (isText(n)) return n.data.length ? n : null;
    if (!isEl(n)) return null;
    if (LEAF[n.nodeName]) return n;
    var ks = n.childNodes;
    for (var i = ks.length - 1; i >= 0; i--) { var l = lastLeaf(ks[i]); if (l) return l; }
    return null;
  }
  function canon(node, off) {
    if (isText(node)) return [node, off];
    if (!isEl(node)) return [node, off];
    var ks = node.childNodes, prev = ks[off - 1], next = ks[off], l;
    if (prev && !isBlockEl(prev)) { l = lastLeaf(prev); if (l && isText(l)) return [l, l.data.length]; }
    if (next) {
      l = firstLeaf(next);
      if (l) return isText(l) ? [l, 0] : [l.parentNode, idx(l)];
    }
    if (prev) { l = lastLeaf(prev); if (l && isText(l)) return [l, l.data.length]; if (l) return [l.parentNode, idx(l) + 1]; }
    return [node, off];
  }
  // what the session is told: a line break or picture stands for the position before it
  function reportPos(p) {
    var n = p[0], o = p[1];
    if (isEl(n)) {
      var c = n.childNodes[o];
      if (c && (c.nodeName === "BR" || c.nodeName === "IMG")) return [c, 0];
    }
    return p;
  }

  function hostOf(n) {
    var e = isEl(n) ? n : n && n.parentNode;
    if (!e || !g.__ed.editable(e)) return null;
    for (; e; e = e.parentNode) { if (isEl(e) && g.__ed.isHost(e)) return e; }
    return doc.designMode === "on" ? doc.body : null;
  }

  function report() {
    var s = selection;
    if (!valid(s)) { g.__ed.report(); return; }
    var host = hostOf(s.focusNode);
    if (!host) { g.__ed.report(); return; }
    var a = reportPos(canon(s.anchorNode, s.anchorOffset)), f = reportPos(canon(s.focusNode, s.focusOffset));
    g.__ed.report(a[0], a[1], f[0], f[1], host);
  }

  function changed() {
    report();
    if (selection._pending) return;
    selection._pending = true;
    setTimeout(function () {
      selection._pending = false;
      doc.dispatchEvent(new g.Event("selectionchange"));
    }, 0);
  }

  // ── editing ───────────────────────────────────────────────

  var CONTAINER = words("UL OL TABLE TBODY THEAD TFOOT TR DL");
  var settings = { separator: "div", css: false };
  var undoStacks = [];

  function sel() { return selection; }

  // the editing host a position is in, or null when it isn't editable
  function context() {
    var fh = g.__ed.focused();
    // focusing an editing host puts the caret at its start unless the selection is already in it
    if (fh && (!valid(selection) || hostOf(selection._range._sc) !== fh || hostOf(selection._range._ec) !== fh)) {
      setSel(fh, 0, fh, 0);
    }
    if (!valid(selection)) return null;
    var r = selection._range;
    var h1 = hostOf(r._sc), h2 = hostOf(r._ec);
    if (!h1 || h1 !== h2) return null;
    return { range: r, host: h1 };
  }

  function setCaret(node, off) { setRange(selection, node, off, node, off); }
  function setSel(an, ao, fn, fo) { setRange(selection, an, ao, fn, fo); }

  // the nearest block that holds text above `n`, or the host
  function closestBlock(n, host) {
    for (var e = isEl(n) ? n : n.parentNode; e && e !== host; e = e.parentNode) {
      if (TEXTBLOCK[e.nodeName] === true) return e;
    }
    return host;
  }
  function inHost(n, host) { return n === host || host.contains(n); }

  function isEmptyText(n) { return isText(n) && n.data === ""; }

  // does a block show anything: text, a line break that isn't its placeholder, a picture
  function hasContent(el) {
    var ks = el.childNodes;
    for (var i = 0; i < ks.length; i++) {
      var c = ks[i];
      if (isText(c) && c.data !== "") return true;
      if (isEl(c)) {
        if (c.nodeName === "IMG" || c.nodeName === "HR") return true;
        if (c.nodeName === "BR") continue;
        if (CONTAINER[c.nodeName] || hasContent(c)) return true;
      }
    }
    return false;
  }
  function isPlaceholderBlock(el) {
    return el.childNodes.length === 1 && el.firstChild.nodeName === "BR";
  }
  // an empty block keeps a line break, or it would collapse to nothing
  function ensurePlaceholder(el) {
    if (!isBlockEl(el)) return;
    if (!hasContent(el) && !el.querySelector("br")) el.appendChild(doc.createElement("br"));
  }
  // ── formatting state ──────────────────────────────────────

  var FORMATS = {
    bold: { tags: words("B STRONG"), make: "b", css: function (s) { return /^(bold|bolder|[6-9]00)$/.test(s.fontWeight); }, prop: "font-weight" },
    italic: { tags: words("I EM"), make: "i", css: function (s) { return /italic|oblique/.test(s.fontStyle); }, prop: "font-style" },
    underline: { tags: words("U"), make: "u", css: function (s) { return /underline/.test(s.textDecoration || s.textDecorationLine || ""); }, prop: "text-decoration" },
    strikethrough: { tags: words("S STRIKE DEL"), make: "s", css: function (s) { return /line-through/.test(s.textDecoration || s.textDecorationLine || ""); }, prop: "text-decoration" },
    subscript: { tags: words("SUB"), make: "sub", css: function () { return false; } },
    superscript: { tags: words("SUP"), make: "sup", css: function () { return false; } }
  };

  // does the format apply to text `t`: it or an ancestor inside the host has the tag or the style
  function hasFormat(t, fmt, host) {
    for (var e = t.parentNode; e && e !== host && e !== doc; e = e.parentNode) {
      if (!isEl(e)) continue;
      if (fmt.tags[e.nodeName]) return true;
      if (e.style && e.getAttribute("style") && fmt.css(e.style)) return true;
    }
    return false;
  }

  // ── splitting trees ───────────────────────────────────────

  // splits `top` so that everything from child `first` of `parent` (a descendant of `top`, or
  // top itself) onward goes into a copy of `top` put after it; returns the copy
  function splitTreeAt(top, parent, first) {
    var cur = parent;
    for (;;) {
      var copy = cur.cloneNode(false);
      for (var n = first; n;) { var nx = n.nextSibling; copy.appendChild(n); n = nx; }
      cur.parentNode.insertBefore(copy, cur.nextSibling);
      if (cur === top) return copy;
      first = copy;
      cur = cur.parentNode;
    }
  }

  // splits `anc` around `node` so that node's branch is alone in an element of its own, which is
  // then unwrapped: the text keeps whatever else it was in
  function liftOut(node, anc) {
    // what follows node inside anc moves to a copy of anc after it
    var after = nextOutside(node, anc);
    if (after) splitTreeAt(anc, after.parent, after.next);
    var before = node;
    var mid = anc;
    if (hasBefore(node, anc)) {
      var p = node.parentNode;
      mid = splitTreeAt(anc, p, node);
    }
    var ks = Array.prototype.slice.call(mid.childNodes);
    ks.forEach(function (k) { mid.parentNode.insertBefore(k, mid); });
    mid.parentNode.removeChild(mid);
  }
  function hasBefore(node, anc) {
    for (var n = node; n !== anc; n = n.parentNode) { if (n.previousSibling) return true; }
    return false;
  }
  // the closest following sibling (and its parent) found going up from node, within anc
  function nextOutside(node, anc) {
    for (var n = node; n !== anc; n = n.parentNode) {
      if (n.nextSibling) return { parent: n.parentNode, next: n.nextSibling };
    }
    return null;
  }

  // ── cleaning up after an edit ─────────────────────────────

  var INLINE_MERGE = words("B STRONG I EM U S STRIKE DEL SUB SUP SPAN FONT A CODE");

  function sameShell(a, b) {
    if (!isEl(a) || !isEl(b) || a.nodeName !== b.nodeName || !INLINE_MERGE[a.nodeName]) return false;
    if (a.attributes.length !== b.attributes.length) return false;
    for (var i = 0; i < a.attributes.length; i++) {
      if (b.getAttribute(a.attributes[i].name) !== a.attributes[i].value) return false;
    }
    return true;
  }

  // merges neighbouring text nodes and equal inline elements, drops empty inline elements; ranges
  // follow (the selection is a live range)
  function tidy(root) {
    var changed = true, guardn = 0;
    while (changed && guardn++ < 20) {
      changed = false;
      (function visit(n) {
        var ks = Array.prototype.slice.call(n.childNodes);
        for (var i = 0; i < ks.length; i++) {
          var c = ks[i];
          if (!c.parentNode) continue;
          if (isText(c)) {
            if (c.data === "") { n.removeChild(c); changed = true; }
          } else if (isEl(c)) {
            visit(c);
            if (INLINE_MERGE[c.nodeName] && c.childNodes.length === 0 && c.parentNode) { n.removeChild(c); changed = true; }
          }
        }
        // neighbours
        var j = 0;
        while (j < n.childNodes.length - 1) {
          var a = n.childNodes[j], b = n.childNodes[j + 1];
          if (isText(a) && isText(b)) { mergeInto(a, b); changed = true; continue; }
          if (sameShell(a, b)) {
            while (b.firstChild) a.appendChild(b.firstChild);
            moveRanges(b, a);
            n.removeChild(b);
            changed = true;
            continue;
          }
          j++;
        }
      })(root);
    }
  }
  // text node b joins a
  function mergeInto(a, b) {
    var at = a.data.length;
    live.forEach(function (r) {
      var p = b.parentNode, i = idx(b);
      if (r._sc === b) { r._sc = a; r._so += at; } else if (r._sc === p && r._so === i) { r._sc = a; r._so = at; }
      if (r._ec === b) { r._ec = a; r._eo += at; } else if (r._ec === p && r._eo === i) { r._ec = a; r._eo = at; }
    });
    a.appendData(b.data);
    b.parentNode.removeChild(b);
  }
  // after the children of `from` moved to the end of `to`
  function moveRanges(from, to) {
    // `from` is about to go: boundaries inside it have already moved with their nodes; boundaries
    // on it itself go to the end of `to`
    live.forEach(function (r) {
      if (r._sc === from) { r._sc = to; r._so += 0; }
      if (r._ec === from) { r._ec = to; r._eo += 0; }
    });
  }

  // ── whitespace ────────────────────────────────────────────

  function preformatted(t) {
    for (var e = t.parentNode; e && e !== doc; e = e.parentNode) {
      if (!isEl(e)) continue;
      if (e.nodeName === "PRE") return true;
      var st = e.getAttribute("style");
      if (st && /white-space\s*:\s*pre/.test(st)) return true;
    }
    return false;
  }
  // the character next to a text node on its line, "" at the end of the line
  function neighbourChar(t, dir) {
    var n = t;
    for (;;) {
      var s = dir < 0 ? n.previousSibling : n.nextSibling;
      while (!s) {
        n = n.parentNode;
        if (!n || isBlockEl(n) || g.__ed.isHost(n)) return "";
        s = dir < 0 ? n.previousSibling : n.nextSibling;
      }
      if (isBlockEl(s) || s.nodeName === "BR") return "";
      var l = dir < 0 ? lastLeaf(s) : firstLeaf(s);
      if (l) {
        if (isText(l)) return dir < 0 ? l.data.charAt(l.data.length - 1) : l.data.charAt(0);
        return "";
      }
      n = s;
    }
  }
  // White space a line would collapse becomes no-break spaces, the way a browser types it:
  // none at the ends of the line or next to another space.
  function fixSpaces(t) {
    var s = t.data;
    if (s.indexOf(" ") < 0 && s.indexOf(NBSP) < 0) return;
    if (preformatted(t)) return;
    var out = "", n = s.length;
    for (var i = 0; i < n;) {
      var c = s.charAt(i);
      if (c !== " " && c !== NBSP) { out += c; i++; continue; }
      var j = i;
      while (j < n && (s.charAt(j) === " " || s.charAt(j) === NBSP)) j++;
      var before = i > 0 ? s.charAt(i - 1) : neighbourChar(t, -1);
      var after = j < n ? s.charAt(j) : neighbourChar(t, 1);
      var run = "";
      for (var k = 0; k < j - i; k++) {
        var last = k === j - i - 1;
        var prevPlain = k > 0 ? run.charAt(k - 1) === " " : before === " ";
        var edge = (k === 0 && before === "") || (last && after === "") || (last && after === " ") || prevPlain || (k === 0 && before === NBSP && false);
        run += edge ? NBSP : " ";
      }
      out += run;
      i = j;
    }
    if (out !== s) {
      // keep ranges: only same-length replacement of characters
      t.replaceData(0, s.length, out);
    }
  }

  // ── events and history ────────────────────────────────────

  function fireInput(host, type, inputType, data, cancelable) {
    var init = { bubbles: true, cancelable: !!cancelable, inputType: inputType, data: data === undefined ? null : data, isComposing: false };
    var ev = new g.InputEvent(type, init);
    host.dispatchEvent(ev);
    return !ev.defaultPrevented;
  }

  function pathOf(host, node) {
    var p = [];
    for (var n = node; n && n !== host; n = n.parentNode) p.unshift(idx(n));
    return p;
  }
  function nodeAt(host, path) {
    var n = host;
    for (var i = 0; i < path.length; i++) { n = n.childNodes[path[i]]; if (!n) return host; }
    return n;
  }
  function snapshotOf(host) {
    var r = valid(selection) ? selection._range : null;
    return {
      host: host, html: host.innerHTML,
      sel: r ? { a: pathOf(host, selection.anchorNode), ao: selection.anchorOffset, f: pathOf(host, selection.focusNode), fo: selection.focusOffset } : null
    };
  }
  function stackOf(host) {
    for (var i = 0; i < undoStacks.length; i++) if (undoStacks[i].host === host) return undoStacks[i];
    var s = { host: host, undo: [], redo: [], key: null, at: null };
    undoStacks.push(s);
    return s;
  }
  // `key` groups the typing and deleting that undo together
  function remember(host, key) {
    var s = stackOf(host);
    var here = valid(selection) ? selection.anchorNode : null;
    var pos = here ? [selection.anchorNode, selection.anchorOffset] : null;
    var same = key && s.key === key && s.at && pos && s.at[0] === pos[0] && s.at[1] === pos[1];
    if (!same) {
      s.undo.push(snapshotOf(host));
      if (s.undo.length > 200) s.undo.shift();
    }
    s.redo = [];
    s.key = key;
    return s;
  }
  function settle(host) {
    var s = stackOf(host);
    s.at = valid(selection) ? [selection.focusNode, selection.focusOffset] : null;
  }
  function restore(host, snap) {
    host.innerHTML = snap.html;
    if (snap.sel) {
      var a = nodeAt(host, snap.sel.a), f = nodeAt(host, snap.sel.f);
      setSel(a, Math.min(snap.sel.ao, len(a)), f, Math.min(snap.sel.fo, len(f)));
    } else setCaret(host, 0);
  }

  // ── pending formats at a caret ────────────────────────────

  var pending = null; // { node, off, set: { bold: true, ... } }
  function pendingFor() {
    if (!pending || !valid(selection) || !selection._range.collapsed) { pending = null; return null; }
    if (pending.node !== selection.focusNode || pending.off !== selection.focusOffset) { pending = null; return null; }
    return pending.set;
  }

  // ── inline formats ────────────────────────────────────────

  // the text nodes of the range, split at its ends so each lies wholly inside; the selection
  // is moved to cover them
  function isolate(range, host) {
    var sc = range._sc, so = range._so, ec = range._ec, eo = range._eo;
    if (isText(ec) && eo > 0 && eo < ec.data.length) { ec.splitText(eo); }
    if (isText(sc) && so > 0 && so < sc.data.length) {
      var piece = sc.splitText(so);
      if (ec === sc) ec = piece;
      sc = piece; so = 0;
      if (ec === piece) eo = eo - so;
    }
    // recompute from the live range, which followed the splits
    sc = range._sc; so = range._so; ec = range._ec; eo = range._eo;
    var out = [];
    walkText(host, function (t) {
      if (t.data === "") return;
      if (cmp(t, 0, sc, so) >= 0 && cmp(t, t.data.length, ec, eo) <= 0) {
        if (/^[ \t\r\n]*$/.test(t.data) && t.parentNode && CONTAINER[t.parentNode.nodeName]) return;
        out.push(t);
      }
    });
    return out;
  }

  function addFormat(t, fmt) {
    var w = doc.createElement(fmt.make);
    t.parentNode.insertBefore(w, t);
    w.appendChild(t);
  }
  function removeFormat(t, fmt, host) {
    var guardn = 0;
    for (;;) {
      var found = null;
      for (var e = t.parentNode; e && e !== host && e !== doc; e = e.parentNode) {
        if (!isEl(e)) continue;
        if (fmt.tags[e.nodeName]) { found = e; break; }
        if (fmt.prop && e.getAttribute("style") && fmt.css(e.style)) { found = e; break; }
      }
      if (!found || guardn++ > 10) return;
      if (fmt.tags[found.nodeName]) liftOut(t, found);
      else {
        // a span carrying the style: drop the property from the part that holds the text
        var s = found.style;
        if (fmt.prop === "text-decoration") s.textDecoration = "none"; else s.removeProperty(fmt.prop);
        if (!found.getAttribute("style")) liftOut(t, found);
        else return;
      }
    }
  }

  function toggleFormat(ctx, name, force) {
    var fmt = FORMATS[name], r = ctx.range, host = ctx.host;
    if (r.collapsed) {
      var cur = formatState(ctx, name);
      var want = force === undefined ? !cur : force;
      var set = (pendingFor() || {});
      set = Object.assign({}, set);
      set[name] = want;
      pending = { node: selection.focusNode, off: selection.focusOffset, set: set };
      return;
    }
    var sc = selection.anchorNode, ao = selection.anchorOffset, fn = selection.focusNode, fo = selection.focusOffset;
    var nodes = isolate(r, host);
    if (!nodes.length) return;
    var all = nodes.every(function (t) { return hasFormat(t, fmt, host); });
    var apply = force === undefined ? !all : force;
    nodes.forEach(function (t) {
      if (apply) { if (!hasFormat(t, fmt, host)) addFormat(t, fmt); }
      else removeFormat(t, fmt, host);
    });
    var first = nodes[0], last = nodes[nodes.length - 1];
    var blocks = [];
    nodes.forEach(function (t) { var b = closestBlock(t, host); if (blocks.indexOf(b) < 0) blocks.push(b); });
    setSel(first, 0, last, last.data.length);
    blocks.forEach(function (b) { tidy(b); });
    // tidy may have merged the end nodes: put the selection back over the same text
    var r2 = selection._range;
    if (!r2.collapsed) { /* the live range followed the merges */ }
  }

  function formatState(ctx, name) {
    var fmt = FORMATS[name], r = ctx.range, host = ctx.host;
    var pend = pendingFor();
    if (pend && pend[name] !== undefined) return pend[name];
    var nodes;
    if (r.collapsed) {
      var c = canon(r._sc, r._so), n = c[0];
      if (isText(n)) return hasFormat(n, fmt, host);
      // an empty line: the formats around it
      var probe = isEl(n) ? n : n.parentNode;
      for (var e = probe; e && e !== host && e !== doc; e = e.parentNode) {
        if (isEl(e) && (fmt.tags[e.nodeName] || (e.getAttribute("style") && fmt.css(e.style)))) return true;
      }
      return false;
    }
    nodes = [];
    walkText(host, function (t) {
      if (t.data === "") return;
      if (cmp(t, t.data.length, r._sc, r._so) > 0 && cmp(t, 0, r._ec, r._eo) < 0) {
        if (/^[ \t\r\n]*$/.test(t.data) && t.parentNode && CONTAINER[t.parentNode.nodeName]) return;
        nodes.push(t);
      }
    });
    if (!nodes.length) return false;
    return nodes.every(function (t) { return hasFormat(t, fmt, host); });
  }

  // ── inserting text ────────────────────────────────────────

  function applyPending(t, host) {
    var set = pendingFor();
    pending = null;
    if (!set) return;
    Object.keys(set).forEach(function (name) {
      var fmt = FORMATS[name];
      if (!fmt) return;
      var has = hasFormat(t, fmt, host);
      if (set[name] && !has) addFormat(t, fmt);
      else if (!set[name] && has) removeFormat(t, fmt, host);
    });
  }

  // inserts `text` (no line breaks) at a collapsed range; leaves the caret after it
  function typeText(ctx, text) {
    var host = ctx.host, r = ctx.range;
    var c = canon(r._sc, r._so), node = c[0], off = c[1];
    var set = pendingFor();
    var t;
    if (set && isText(node)) {
      // a node of its own for the typed text, so the format can be set on it alone
      if (off < node.data.length) node.splitText(off);
      t = doc.createTextNode(text);
      node.parentNode.insertBefore(t, node.nextSibling);
      applyPending(t, host);
      fixSpaces(t);
      setCaret(t, t.data.length);
      tidy(closestBlock(t, host));
      return;
    }
    if (isText(node)) {
      node.insertData(off, text);
      t = node;
      fixSpaces(t);
      var at = Math.min(off + text.length, t.data.length);
      setCaret(t, at);
      return;
    }
    // an element position: next to text there, in an empty line, or in an empty host
    var ks = node.childNodes, prev = ks[off - 1], next = ks[off];
    if (isPlaceholderBlock(node) || (node === host && isPlaceholderBlock(host))) {
      node.removeChild(node.firstChild);
      prev = null; next = null;
    }
    if (prev && isText(prev)) { t = prev; t.appendData(text); }
    else if (next && isText(next)) { t = next; t.insertData(0, text); }
    else {
      t = doc.createTextNode(text);
      node.insertBefore(t, next || null);
    }
    var pos = prev && isText(prev) ? prev.data.length : text.length;
    if (set) {
      var piece = t;
      applyPending(piece, host);
    }
    fixSpaces(t);
    setCaret(t, Math.min(pos, t.data.length));
    if (set) tidy(closestBlock(t, host));
  }

  // ── blocks ────────────────────────────────────────────────

  // the children of `host` that aren't in a block become blocks of their own, so there is a
  // paragraph to split, move or make an item of. Returns the block holding the node.
  function blockOf(node, host) {
    var b = closestBlock(node, host);
    if (b !== host) return b;
    // a run of inline nodes directly in the host
    var top = node;
    while (top.parentNode !== host) top = top.parentNode;
    if (isBlockEl(top)) return top;
    var first = top, last = top;
    while (first.previousSibling && !isBlockEl(first.previousSibling)) first = first.previousSibling;
    while (last.nextSibling && !isBlockEl(last.nextSibling)) last = last.nextSibling;
    var div = doc.createElement(settings.separator === "p" ? "p" : "div");
    host.insertBefore(div, first);
    var n = first;
    while (n) {
      var nx = n === last ? null : n.nextSibling;
      div.appendChild(n);
      n = nx;
    }
    return div;
  }

  // where a point goes after `blockOf` moved nodes: text nodes stay valid, element points are
  // followed by the live range
  function newBlock(tagName) {
    return doc.createElement(tagName);
  }

  function lineBreak(ctx) {
    var r = ctx.range;
    var br = doc.createElement("br");
    var c = canon(r._sc, r._so), node = c[0], off = c[1];
    if (isText(node)) {
      if (off < node.data.length) { node.splitText(off); }
      node.parentNode.insertBefore(br, node.nextSibling);
    } else {
      node.insertBefore(br, node.childNodes[off] || null);
      if (node.childNodes.length && node.lastChild === br && !(br.previousSibling && br.previousSibling.nodeName === "BR")) {
        // a line break at the end of a line needs another to show the new line
      }
    }
    // a break at the very end of a block shows no new line: add a second one
    var parent = br.parentNode;
    if (!br.nextSibling && isBlockEl(parent) || (!br.nextSibling && g.__ed.isHost(parent))) parent.appendChild(doc.createElement("br"));
    setCaret(br.parentNode, idx(br) + 1);
  }

  function insertParagraph(ctx) {
    var r = ctx.range, host = ctx.host;
    var c = canon(r._sc, r._so), node = c[0], off = c[1];
    var block = blockOf(node, host);
    // the position again, now that a bare run may have moved into a block
    if (isEl(node) && node === host) { var c2 = canon(r._sc, r._so); node = c2[0]; off = c2[1]; }
    if (block.nodeName === "TD" || block.nodeName === "TH" || block.nodeName === "CAPTION") {
      lineBreak(ctx);
      return;
    }
    if (block.nodeName === "LI" && !hasContent(block) && !(block.querySelector("ul, ol"))) {
      // Enter in an empty item leaves the list
      var left = outdentItem(block);
      var lf = left && firstLeaf(left);
      if (lf && isText(lf)) setCaret(lf, 0); else if (left) setCaret(left, 0);
      return;
    }
    // where to cut: before `first` inside `parent`
    var parent, first;
    if (isText(node)) {
      if (off === 0) { parent = node.parentNode; first = node; }
      else if (off >= node.data.length) { parent = node.parentNode; first = node.nextSibling; }
      else { var rest = node.splitText(off); parent = node.parentNode; first = rest; }
    } else { parent = node; first = node.childNodes[off] || null; }
    // a break right before the cut belongs to the line that ends here
    var right;
    if (!first) {
      // at the end of the block: a new empty one
      right = block.cloneNode(false);
      right.removeAttribute("id");
      var wrapChain = [];
      for (var e = parent; e !== block; e = e.parentNode) wrapChain.push(e);
      // open inline elements stay open on the new line
      var inner = right;
      for (var i = wrapChain.length - 1; i >= 0; i--) { var cp = wrapChain[i].cloneNode(false); inner.appendChild(cp); inner = cp; }
      block.parentNode.insertBefore(right, block.nextSibling);
      if (!hasContent(block)) ensurePlaceholder(block);
    } else {
      right = splitTreeAt(block, parent, first);
      if (right.hasAttribute && right.hasAttribute("id")) right.removeAttribute("id");
    }
    if (/^H[1-6]$/.test(block.nodeName) && !hasContentAfterCaret(right)) {
      // Enter at the end of a heading starts an ordinary paragraph
      var para = doc.createElement(settings.separator === "p" ? "p" : "div");
      while (right.firstChild) para.appendChild(right.firstChild);
      right.parentNode.replaceChild(para, right);
      right = para;
    }
    tidy(block);
    pruneInline(block);
    pruneInline(right);
    ensurePlaceholder(block);
    ensurePlaceholder(right);
    // a nested list item that split holds its sublist in the new item: leave it with the new one
    var landing = firstLeaf(right);
    if (landing && isText(landing)) setCaret(landing, 0);
    else if (landing) setCaret(landing.parentNode, idx(landing));
    else setCaret(right, 0);
  }
  function hasContentAfterCaret(right) { return hasContent(right); }

  // removes empty inline elements from a block (the copies a split leaves behind)
  function pruneInline(block) {
    (function visit(n) {
      var ks = Array.prototype.slice.call(n.childNodes);
      ks.forEach(function (c) {
        if (isEl(c) && !isBlockEl(c) && !LEAF[c.nodeName]) {
          visit(c);
          if (!c.firstChild && c.parentNode) c.parentNode.removeChild(c);
        } else if (isEl(c) && isBlockEl(c) && !CONTAINER[c.nodeName]) {
          // blocks inside a block (a nested list's items) are left alone
        }
        if (isText(c) && c.data === "" && c.parentNode) c.parentNode.removeChild(c);
      });
    })(block);
  }

  // ── lists ─────────────────────────────────────────────────

  function listOf(li) {
    var p = li.parentNode;
    return p && (p.nodeName === "UL" || p.nodeName === "OL") ? p : null;
  }
  function liOf(n, host) {
    for (var e = isEl(n) ? n : n.parentNode; e && e !== host; e = e.parentNode) if (e.nodeName === "LI") return e;
    return null;
  }

  // the blocks the selection touches, in order: the paragraphs, list items and cells that hold
  // text (a block that only holds other blocks isn't one)
  function selectedBlocks(ctx) {
    var r = ctx.range, host = ctx.host;
    var sc = r._sc, so = r._so, ec = r._ec, eo = r._eo;
    var a = canon(sc, so)[0], b = canon(ec, eo)[0];
    var startB = blockOf(a, host);
    // blockOf may have changed the tree: take the end from the live range again
    b = canon(r._ec, r._eo)[0];
    var endB = blockOf(b, host);
    var out = [];
    var all = [];
    (function collect(n) {
      var ks = n.childNodes;
      for (var i = 0; i < ks.length; i++) {
        var c = ks[i];
        if (isEl(c)) {
          if (TEXTBLOCK[c.nodeName] === true) {
            // a block with direct text or inline content
            var direct = false;
            for (var j = 0; j < c.childNodes.length; j++) {
              var d = c.childNodes[j];
              if ((isText(d) && d.data.trim() !== "") || (isEl(d) && !isBlockEl(d) && d.nodeName !== "BR" ) || (isEl(d) && d.nodeName === "BR")) direct = true;
            }
            if (direct || c.childNodes.length === 0) all.push(c);
            collect(c);
          } else collect(c);
        }
      }
    })(host);
    var si = all.indexOf(startB), ei = all.indexOf(endB);
    if (si < 0 || ei < 0) return [startB];
    return all.slice(si, ei + 1);
  }

  function listItemFor(block) {
    var li = doc.createElement("li");
    while (block.firstChild) li.appendChild(block.firstChild);
    block.parentNode.replaceChild(li, block);
    return li;
  }

  // wraps neighbouring items in new lists of `type`, joins them with a list of the same kind
  // next to them
  function wrapItems(items, type) {
    var groups = [];
    items.forEach(function (li) {
      var g0 = groups[groups.length - 1];
      if (g0 && g0[g0.length - 1].nextSibling === li) g0.push(li); else groups.push([li]);
    });
    groups.forEach(function (grp) {
      var list = doc.createElement(type);
      grp[0].parentNode.insertBefore(list, grp[0]);
      grp.forEach(function (li) { list.appendChild(li); });
      var prev = list.previousSibling;
      if (prev && prev.nodeName === type) { while (list.firstChild) prev.appendChild(list.firstChild); list.parentNode.removeChild(list); list = prev; }
      var next = list.nextSibling;
      if (next && next.nodeName === type) { while (next.firstChild) list.appendChild(next.firstChild); next.parentNode.removeChild(next); }
    });
  }

  function toggleList(ctx, type) {
    var blocks = selectedBlocks(ctx), host = ctx.host;
    var allIn = blocks.every(function (b) { var li = b.nodeName === "LI" ? b : null; return li && listOf(li) && listOf(li).nodeName === type; });
    var sc = selection.anchorNode, ao = selection.anchorOffset, fn = selection.focusNode, fo = selection.focusOffset;
    var ac = canon(sc, ao), fc = canon(fn, fo);
    if (allIn) {
      blocks.slice().reverse().forEach(function (li) { unlistItem(li); });
    } else {
      var items = [];
      blocks.forEach(function (b) {
        if (b.nodeName === "LI") {
          var l = listOf(b);
          if (l && l.nodeName !== type) {
            // another kind of list: the whole list changes kind
            var nl = doc.createElement(type);
            while (l.firstChild) nl.appendChild(l.firstChild);
            l.parentNode.replaceChild(nl, l);
          }
          return;
        }
        if (b === host || b.nodeName === "TD" || b.nodeName === "TH") return;
        items.push(listItemFor(b));
      });
      wrapItems(items, type);
    }
    setSel(ac[0], Math.min(ac[1], len(ac[0])), fc[0], Math.min(fc[1], len(fc[0])));
  }

  // an item stops being one: its text becomes a paragraph after what came before it
  function unlistItem(li) {
    var list = listOf(li);
    if (!list) return null;
    var div = doc.createElement(settings.separator === "p" ? "p" : "div");
    var nested = [];
    while (li.firstChild) {
      var c = li.firstChild;
      if (c.nodeName === "UL" || c.nodeName === "OL") nested.push(li.removeChild(c));
      else div.appendChild(c);
    }
    if (!div.firstChild) div.appendChild(doc.createElement("br"));
    // items after this one go to a list of their own after the paragraph
    var after = li.nextSibling;
    var parentLi = list.parentNode && list.parentNode.nodeName === "LI" ? list.parentNode : null;
    if (parentLi) {
      // a nested item goes up a level instead
      while (div.firstChild) li.insertBefore(div.firstChild, li.firstChild);
      nested.forEach(function (n) { li.appendChild(n); });
      outdentItem(li);
      return li;
    }
    var tail = null;
    if (after) { tail = list.cloneNode(false); while (after) { var nx = after.nextSibling; tail.appendChild(after); after = nx; } }
    list.parentNode.insertBefore(div, list.nextSibling);
    li.parentNode.removeChild(li);
    var ref = div.nextSibling;
    nested.forEach(function (n) { list.parentNode.insertBefore(n, ref); });
    if (tail) list.parentNode.insertBefore(tail, ref);
    if (!list.firstChild) list.parentNode.removeChild(list);
    return div;
  }

  // one level up: out of the sublist into the item that holds it; at the top, out of the list
  function outdentItem(li) {
    var list = listOf(li);
    if (!list) return false;
    var parentLi = list.parentNode.nodeName === "LI" ? list.parentNode : null;
    if (!parentLi) return unlistItem(li);
    // items after this one become its own sublist
    var after = li.nextSibling;
    if (after) {
      var sub = list.cloneNode(false);
      while (after) { var nx = after.nextSibling; sub.appendChild(after); after = nx; }
      li.appendChild(sub);
    }
    parentLi.parentNode.insertBefore(li, parentLi.nextSibling);
    if (!list.firstChild) list.parentNode.removeChild(list);
    return true;
  }

  function indentItem(li) {
    var prev = li.previousElementSibling;
    var list = listOf(li);
    if (!prev || !list) return false;
    var sub = prev.lastElementChild;
    if (!sub || (sub.nodeName !== "UL" && sub.nodeName !== "OL")) {
      sub = doc.createElement(list.nodeName);
      prev.appendChild(sub);
    }
    sub.appendChild(li);
    return true;
  }

  var INDENT = "margin: 0 0 0 40px; border: none; padding: 0px;";
  function indent(ctx, out) {
    var blocks = selectedBlocks(ctx), did = false;
    var ac = canon(selection.anchorNode, selection.anchorOffset), fc = canon(selection.focusNode, selection.focusOffset);
    blocks = blocks.slice();
    if (out) blocks.reverse();
    blocks.forEach(function (b) {
      if (b.nodeName === "LI") { did = (out ? outdentItem(b) : indentItem(b)) || did; return; }
      if (b === ctx.host) return;
      if (out) {
        var q = b.parentNode;
        while (q && q !== ctx.host && q.nodeName !== "BLOCKQUOTE") q = q.parentNode;
        if (q && q.nodeName === "BLOCKQUOTE") {
          while (q.firstChild) q.parentNode.insertBefore(q.firstChild, q);
          q.parentNode.removeChild(q);
          did = true;
        }
      } else {
        var bq = doc.createElement("blockquote");
        bq.setAttribute("style", INDENT);
        b.parentNode.insertBefore(bq, b);
        bq.appendChild(b);
        did = true;
      }
    });
    setSel(ac[0], Math.min(ac[1], len(ac[0])), fc[0], Math.min(fc[1], len(fc[0])));
    return did;
  }

  // ── deleting ──────────────────────────────────────────────

  // the caret positions of a host in order: every place a caret can stand
  function stops(host) {
    var out = [], prev = null, brk = true;
    function push(node, off, blk) { prev = { node: node, off: off, blk: blk, text: isText(node) }; out.push(prev); }
    (function walk(n) {
      var ks = n.childNodes;
      for (var i = 0; i < ks.length; i++) {
        var c = ks[i];
        if (isText(c)) {
          var L = c.data.length;
          if (!L) continue;
          var cb = closestBlock(c, host);
          for (var k = 0; k <= L; k++) {
            if (k === 0 && prev && prev.text && prev.off === len(prev.node) && prev.blk === cb && !brk) continue;
            push(c, k, cb);
          }
          brk = false;
        } else if (isEl(c)) {
          if (c.nodeName === "BR") {
            var b = closestBlock(c, host);
            if (!prev || prev.blk !== b || brk) push(c.parentNode, idx(c), b);
            brk = true;
          } else if (c.nodeName === "IMG") {
            push(c.parentNode, idx(c), closestBlock(c, host));
            brk = false;
          } else if (TEXTBLOCK[c.nodeName] === true && !firstLeaf(c)) {
            push(c, 0, c);
            brk = true;
          } else walk(c);
        }
      }
    })(host);
    return out;
  }
  function stopIndex(list, node, off) {
    var c = canon(node, off);
    for (var i = 0; i < list.length; i++) {
      var s = list[i];
      if (s.node === c[0] && s.off === c[1]) return i;
    }
    // the first stop at or after the position
    for (var j = 0; j < list.length; j++) if (cmp(list[j].node, list[j].off, node, off) >= 0) return j;
    return list.length - 1;
  }

  function removeNode(n) { if (n.parentNode) n.parentNode.removeChild(n); }

  // removes `n` and the elements above it that it leaves empty
  function removeEmptyUp(n, host) {
    var p = n.parentNode;
    removeNode(n);
    while (p && p !== host && !p.firstChild && !isBlockEl(p) && !LEAF[p.nodeName]) { var q = p.parentNode; removeNode(p); p = q; }
    return p;
  }

  // joins block `b` to the end of block `a`; the caret goes where they meet
  function mergeBlocks(a, b, host) {
    if (a === b) return;
    var wasHolder = isPlaceholderBlock(a) || !hasContent(a);
    if (wasHolder) { while (a.firstChild) a.removeChild(a.firstChild); }
    var at = a.childNodes.length;
    var bHolder = isPlaceholderBlock(b) || !hasContent(b);
    var land = a.lastChild;
    var landOff = at;
    if (bHolder) {
      // nothing to bring over
    } else {
      // an item's sublist stays with the item
      while (b.firstChild) a.appendChild(b.firstChild);
    }
    var bp = b.parentNode;
    removeNode(b);
    // lists left without items go
    var q = bp;
    while (q && q !== host && !q.firstChild && !isBlockEl(q) === false && CONTAINER[q.nodeName]) { var qq = q.parentNode; removeNode(q); q = qq; }
    if (!hasContent(a)) { while (a.firstChild) a.removeChild(a.firstChild); a.appendChild(doc.createElement("br")); setCaret(a, 0); return; }
    // the caret: where block b's content begins in a
    var node = a.childNodes[landOff];
    if (!node) { var ll = lastLeaf(a); if (ll && isText(ll)) setCaret(ll, ll.data.length); else setCaret(a, a.childNodes.length); return; }
    var f = firstLeaf(node);
    if (wasHolder) { if (f && isText(f)) setCaret(f, 0); else setCaret(a, landOff); return; }
    var prevLeaf = lastLeaf(a.childNodes[landOff - 1] || a);
    if (prevLeaf && isText(prevLeaf) && (landOff > 0)) {
      // end of the text that was there before
      var lastBefore = null;
      for (var i = landOff - 1; i >= 0; i--) { var l2 = lastLeaf(a.childNodes[i]); if (l2) { lastBefore = l2; break; } }
      if (lastBefore && isText(lastBefore)) { setCaret(lastBefore, lastBefore.data.length); return; }
    }
    if (f && isText(f)) setCaret(f, 0); else setCaret(a, landOff);
  }

  // deletes what the range holds and joins the blocks at its ends
  function deleteRange(ctx) {
    var r = ctx.range, host = ctx.host;
    if (r.collapsed) return;
    var sb = closestBlock(r._sc, host), eb = closestBlock(r._ec, host);
    // a start or end in bare text at the top of the host: those lines are one block
    r.deleteContents();
    var sc = r._sc, so = r._so;
    var c = canon(sc, so);
    if (sb !== eb && sb !== host && eb !== host && sb.parentNode && eb.parentNode && sb !== eb && inHost(sb, host) && inHost(eb, host)) {
      var cellA = closestCell(sb), cellB = closestCell(eb);
      if (cellA === cellB) {
        r = selection._range;
        mergeBlocks(sb, eb, host);
        tidy(sb);
        return;
      }
    }
    if (sb === host || eb === host) {
      // a bare line and a block: the block's text joins the bare line
      if (sb === host && eb !== host && eb.parentNode && !closestCell(eb)) {
        // the text before the caret stays loose in the host: bring the rest of the block over
        var pos = [selection._range._sc, selection._range._so];
        var movers = Array.prototype.slice.call(eb.childNodes);
        var anchor = eb.previousSibling;
        if (anchor && !isBlockEl(anchor)) {
          movers.forEach(function (m) { host.insertBefore(m, eb); });
          removeNode(eb);
        }
      } else if (eb === host && sb !== host && sb.parentNode && !closestCell(sb)) {
        var nxt = sb.nextSibling;
        while (nxt && !isBlockEl(nxt)) { var nn = nxt.nextSibling; sb.appendChild(nxt); nxt = nn; }
      }
    }
    var blk = closestBlock(selection.focusNode, host);
    if (blk !== host) ensurePlaceholder(blk); else if (!host.firstChild) { /* an empty host stays empty */ }
    tidy(host);
    var cc = canon(selection.focusNode, selection.focusOffset);
    setCaret(cc[0], cc[1]);
  }
  function closestCell(n) {
    for (var e = n; e; e = e.parentNode) if (e.nodeName === "TD" || e.nodeName === "TH") return e;
    return null;
  }

  // one step back (-1) or forward (1) from a collapsed caret
  function deleteStep(ctx, dir) {
    var r = ctx.range, host = ctx.host;
    var node = r._sc, off = r._so;
    var c = canon(node, off);
    node = c[0]; off = c[1];
    var block = closestBlock(node, host);
    // inside a text node: one character
    if (isText(node)) {
      if (dir < 0 && off > 0) { removeChars(node, off - 1, off, host); return true; }
      if (dir > 0 && off < node.data.length) { removeChars(node, off, off + 1, host); return true; }
    }
    // an item's first position: the item stops being one
    if (dir < 0 && block.nodeName === "LI" && atBlockStart(node, off, block)) {
      var held = unlistOrOutdent(block);
      if (node.isConnected && isText(node)) setCaret(node, off);
      else if (held) setCaret(held, 0);
      return true;
    }
    var list = stops(host);
    var i = stopIndex(list, node, off);
    var j = i + dir;
    if (j < 0 || j >= list.length) return false;
    var from = list[i], to = list[j];
    if (to.blk !== from.blk) {
      // at a block edge: join the two blocks
      var a = dir < 0 ? to.blk : from.blk, b = dir < 0 ? from.blk : to.blk;
      if (a === host || b === host) return joinBare(host, a, b);
      if (closestCell(a) !== closestCell(b)) return false;
      if (CONTAINER[a.nodeName]) return false;
      mergeBlocks(a, b, host);
      tidy(host);
      return true;
    }
    // inside the block: the character or line break the step crosses
    var target = dir < 0 ? to : from;
    // the stop pair (to, from) sit on either side of one character or one line break
    var lo = dir < 0 ? to : from, hi = dir < 0 ? from : to;
    if (lo.node === hi.node && isText(lo.node)) { removeChars(lo.node, lo.off, hi.off, host); return true; }
    if (isText(lo.node) && isText(hi.node)) {
      // across two text nodes: the last character of the first or the first of the second
      removeChars(hi.node, 0, 1, host); return true;
    }
    if (isText(hi.node) && !isText(lo.node)) {
      // a line break (or picture) lies between: remove it
      var el = lo.node.childNodes[lo.off];
      if (el && (el.nodeName === "BR" || el.nodeName === "IMG")) { removeNode(el); setCaret(hi.node, hi.off === 0 ? 0 : hi.off); tidyBlock(block, host); return true; }
    }
    if (isText(lo.node) && !isText(hi.node)) {
      var el2 = hi.node.childNodes[hi.off];
      if (el2 && (el2.nodeName === "BR" || el2.nodeName === "IMG")) { removeNode(el2); setCaret(lo.node, lo.off); tidyBlock(block, host); return true; }
    }
    return false;
  }
  function tidyBlock(block, host) { if (block !== host) { tidy(block); ensurePlaceholder(block); } }
  function joinBare(host, a, b) {
    // one side is bare text at the top of the host
    if (a === host) {
      // the line before is loose: it joins the block after it
      var loose = b.previousSibling;
      if (!loose || isBlockEl(loose)) return false;
      var first = b.firstChild;
      var m = loose;
      var runs = [];
      while (m && !isBlockEl(m)) { runs.unshift(m); m = m.previousSibling; }
      var ref = first;
      var tail = lastLeaf(runs[runs.length - 1]);
      runs.forEach(function (n) { b.insertBefore(n, ref); });
      if (tail && isText(tail)) setCaret(tail, tail.data.length);
      else setCaret(b, runs.length);
      tidy(b);
      return true;
    }
    // the block before joins the loose text after it
    var next = a.nextSibling;
    if (!next || isBlockEl(next)) return false;
    var tailLeaf = lastLeaf(a);
    var m2 = next;
    while (m2 && !isBlockEl(m2)) { var nx = m2.nextSibling; a.appendChild(m2); m2 = nx; }
    if (tailLeaf && isText(tailLeaf)) setCaret(tailLeaf, tailLeaf.data.length); else setCaret(a, 0);
    tidy(a);
    return true;
  }
  function unlistOrOutdent(li) {
    var list = listOf(li);
    if (!list) return null;
    return list.parentNode.nodeName === "LI" ? outdentItem(li) : unlistItem(li);
  }
  function atBlockStart(node, off, block) {
    var first = firstLeaf(block);
    if (!first) return true;
    if (isText(first)) return node === first && off === 0 || (isText(node) && off === 0 && first === node);
    return node === block && off === 0;
  }

  function removeChars(t, from, to, host) {
    t.deleteData(from, to - from);
    var block = closestBlock(t, host);
    if (t.data === "") {
      var p = t.parentNode, i = idx(t);
      removeEmptyUp(t, host);
      if (block !== host) ensurePlaceholder(block);
      var landing = p && p.isConnected ? canon(p, Math.min(i, p.childNodes.length)) : [block, 0];
      setCaret(landing[0], landing[1]);
      tidyBlock(block, host);
      return;
    }
    fixSpaces(t);
    setCaret(t, Math.min(from, t.data.length));
  }

  // ── insertHTML ────────────────────────────────────────────

  function insertFragment(ctx, frag) {
    var host = ctx.host;
    if (!ctx.range.collapsed) deleteRange(ctx);
    var r = selection._range;
    var kidsOf = Array.prototype.slice.call(frag.childNodes);
    if (!kidsOf.length) return;
    var blocky = kidsOf.some(function (n) { return isBlockEl(n); });
    var c = canon(r._sc, r._so), node = c[0], off = c[1];
    if (!blocky) {
      // inline content goes in at the caret
      var rr = doc.createRange();
      if (isText(node)) { rr.setStart(node, off); } else { rr.setStart(node, off); }
      rr.collapse(true);
      var last = kidsOf[kidsOf.length - 1];
      if (isPlaceholderBlock(isEl(node) ? node : node.parentNode)) { var ph = isEl(node) ? node : node.parentNode; if (ph !== host || true) { ph.removeChild(ph.firstChild); rr.setStart(ph, 0); rr.collapse(true); } }
      rr.insertNode(frag);
      tidy(closestBlock(last.parentNode || host, host));
      var end = lastLeaf(last);
      if (end && isText(end)) { fixSpaces(end); setCaret(end, end.data.length); }
      else if (last.parentNode) setCaret(last.parentNode, idx(last) + 1);
      return;
    }
    // blocks: cut the paragraph at the caret and put them between the halves
    var block = blockOf(node, host);
    var c2 = canon(r._sc, r._so); node = c2[0]; off = c2[1];
    var parent, first;
    if (isText(node)) {
      if (off === 0) { parent = node.parentNode; first = node; }
      else if (off >= node.data.length) { parent = node.parentNode; first = node.nextSibling; }
      else { first = node.splitText(off); parent = node.parentNode; }
    } else { parent = node; first = node.childNodes[off] || null; }
    var emptyBlock = !hasContent(block);
    var rightPart = null;
    if (block !== host) {
      rightPart = first ? splitTreeAt(block, parent, first) : null;
    }
    var blocks = kidsOf;
    var firstB = blocks[0], lastB = blocks[blocks.length - 1];
    var ref = block === host ? first : (rightPart || block.nextSibling);
    var holder = block === host ? host : block.parentNode;
    // the first block's content joins the paragraph that was cut, unless that was empty
    var landing = null;
    if (block !== host && !emptyBlock && isBlockEl(firstB) && TEXTBLOCK[firstB.nodeName] && !firstB.querySelector("ul, ol, table, div, p") && block.nodeName !== "LI") {
      var tailLeaf = lastLeaf(block);
      while (firstB.firstChild) block.appendChild(firstB.firstChild);
      blocks = blocks.slice(1);
    }
    if (emptyBlock && block !== host) {
      // an empty line: the new blocks take its place
      while (block.firstChild) block.removeChild(block.firstChild);
    }
    blocks.forEach(function (b) { holder.insertBefore(b, ref); });
    if (rightPart && !hasContent(rightPart)) { removeNode(rightPart); }
    if (block !== host && emptyBlock && !hasContent(block) && blocks.length) removeNode(block);
    if (rightPart && rightPart.parentNode && !hasContent(rightPart)) removeNode(rightPart);
    tidy(host);
    var endLeaf = lastLeaf(blocks.length ? blocks[blocks.length - 1] : (block.parentNode ? block : host));
    if (endLeaf && isText(endLeaf)) { fixSpaces(endLeaf); setCaret(endLeaf, endLeaf.data.length); }
    else if (endLeaf) setCaret(endLeaf.parentNode, idx(endLeaf));
    else if (blocks.length && blocks[blocks.length - 1].parentNode) setCaret(blocks[blocks.length - 1], 0);
  }

  function htmlFragment(html) {
    var t = doc.createElement("template");
    t.innerHTML = html;
    var f = doc.createDocumentFragment();
    while (t.firstChild) f.appendChild(t.firstChild);
    return f;
  }

  // text with line breaks as paragraphs: what a plain paste is
  function insertPlain(ctx, text, inputType) {
    var lines = String(text).replace(/\r\n?/g, "\n").split("\n");
    lines.forEach(function (line, i) {
      if (i > 0) insertParagraph(contextNow(ctx));
      if (line !== "") {
        var cx = contextNow(ctx);
        if (!cx.range.collapsed) deleteRange(cx);
        typeText(contextNow(ctx), line);
      }
    });
  }
  function contextNow(ctx) { return { range: selection._range, host: ctx.host }; }

  // ── commands ──────────────────────────────────────────────

  var KNOWN = words("bold italic underline strikethrough subscript superscript removeformat insertunorderedlist insertorderedlist indent outdent inserthtml inserttext insertparagraph insertlinebreak inserthorizontalrule insertimage delete forwarddelete selectall undo redo formatblock justifyleft justifycenter justifyright justifyfull forecolor hilitecolor backcolor fontname fontsize createlink unlink defaultparagraphseparator stylewithcss usecss copy cut paste enableobjectresizing enableinlinetableediting contentreadonly");

  var inputTypes = {
    bold: "formatBold", italic: "formatItalic", underline: "formatUnderline", strikethrough: "formatStrikeThrough",
    subscript: "formatSubscript", superscript: "formatSuperscript", removeformat: "formatRemove",
    insertunorderedlist: "insertUnorderedList", insertorderedlist: "insertOrderedList", indent: "formatIndent", outdent: "formatOutdent",
    inserthtml: "insertText", inserttext: "insertText", insertparagraph: "insertParagraph", insertlinebreak: "insertLineBreak",
    inserthorizontalrule: "insertHorizontalRule", delete: "deleteContentBackward", forwarddelete: "deleteContentForward",
    undo: "historyUndo", redo: "historyRedo", justifyleft: "formatJustifyLeft", justifycenter: "formatJustifyCenter",
    justifyright: "formatJustifyRight", justifyfull: "formatJustifyFull", forecolor: "formatFontColor", hilitecolor: "formatBackColor",
    backcolor: "formatBackColor", fontname: "formatFontName", createlink: "insertLink", insertimage: "insertText"
  };
  var typing = words("inserttext delete forwarddelete");

  function walkBlocksStyle(ctx, fn) { selectedBlocks(ctx).forEach(function (b) { if (b !== ctx.host) fn(b); }); }

  function wrapSpan(ctx, css) {
    var r = ctx.range;
    if (r.collapsed) return;
    var nodes = isolate(r, ctx.host);
    nodes.forEach(function (t) {
      var sp = doc.createElement("span");
      sp.setAttribute("style", css);
      t.parentNode.insertBefore(sp, t);
      sp.appendChild(t);
    });
    if (nodes.length) setSel(nodes[0], 0, nodes[nodes.length - 1], nodes[nodes.length - 1].data.length);
  }

  function formatBlock(ctx, tagName) {
    tagName = String(tagName).replace(/[<>]/g, "").toLowerCase();
    if (!/^(div|p|h[1-6]|blockquote|pre|address)$/.test(tagName)) return false;
    var ac = canon(selection.anchorNode, selection.anchorOffset), fc = canon(selection.focusNode, selection.focusOffset);
    walkBlocksStyle(ctx, function (b) {
      if (b.nodeName === "LI" || b.nodeName === "TD" || b.nodeName === "TH") return;
      var nb = doc.createElement(tagName);
      while (b.firstChild) nb.appendChild(b.firstChild);
      b.parentNode.replaceChild(nb, b);
    });
    setSel(ac[0], Math.min(ac[1], len(ac[0])), fc[0], Math.min(fc[1], len(fc[0])));
    return true;
  }

  function stripFormats(ctx) {
    var r = ctx.range, host = ctx.host;
    if (r.collapsed) return;
    var nodes = isolate(r, host);
    Object.keys(FORMATS).forEach(function (name) {
      nodes.forEach(function (t) { removeFormat(t, FORMATS[name], host); });
    });
    ["A", "SPAN", "FONT", "CODE"].forEach(function (tn) {
      nodes.forEach(function (t) {
        for (var e = t.parentNode; e && e !== host; e = e.parentNode) if (e.nodeName === tn && e.parentNode) { liftOut(t, e); break; }
      });
    });
    if (nodes.length) {
      setSel(nodes[0], 0, nodes[nodes.length - 1], nodes[nodes.length - 1].data.length);
      host && tidy(host);
    }
  }

  function selectedText() {
    if (!valid(selection) || selection._range.collapsed) return "";
    var tmp = doc.createElement("div");
    tmp.appendChild(selection._range.cloneContents());
    return tmp.innerText;
  }

  var commands = {
    bold: function (c) { toggleFormat(c, "bold"); },
    italic: function (c) { toggleFormat(c, "italic"); },
    underline: function (c) { toggleFormat(c, "underline"); },
    strikethrough: function (c) { toggleFormat(c, "strikethrough"); },
    subscript: function (c) { toggleFormat(c, "subscript"); },
    superscript: function (c) { toggleFormat(c, "superscript"); },
    removeformat: stripFormats,
    insertunorderedlist: function (c) { toggleList(c, "UL"); },
    insertorderedlist: function (c) { toggleList(c, "OL"); },
    indent: function (c) { return indent(c, false); },
    outdent: function (c) { return indent(c, true); },
    inserthtml: function (c, v) { insertFragment(c, htmlFragment(String(v))); },
    inserttext: function (c, v) { insertPlain(c, v, "insertText"); },
    insertparagraph: function (c) { if (!c.range.collapsed) deleteRange(c); insertParagraph(contextNow(c)); },
    insertlinebreak: function (c) { if (!c.range.collapsed) deleteRange(c); lineBreak(contextNow(c)); },
    inserthorizontalrule: function (c) { insertFragment(c, htmlFragment("<hr>")); },
    insertimage: function (c, v) { var i = doc.createElement("img"); i.setAttribute("src", String(v)); var f = doc.createDocumentFragment(); f.appendChild(i); insertFragment(c, f); },
    delete: function (c) { if (!c.range.collapsed) deleteRange(c); else deleteStep(c, -1); },
    forwarddelete: function (c) { if (!c.range.collapsed) deleteRange(c); else deleteStep(c, 1); },
    formatblock: function (c, v) { return formatBlock(c, v); },
    justifyleft: function (c) { walkBlocksStyle(c, function (b) { b.style.textAlign = "left"; }); },
    justifycenter: function (c) { walkBlocksStyle(c, function (b) { b.style.textAlign = "center"; }); },
    justifyright: function (c) { walkBlocksStyle(c, function (b) { b.style.textAlign = "right"; }); },
    justifyfull: function (c) { walkBlocksStyle(c, function (b) { b.style.textAlign = "justify"; }); },
    forecolor: function (c, v) { wrapSpan(c, "color: " + v + ";"); },
    hilitecolor: function (c, v) { wrapSpan(c, "background-color: " + v + ";"); },
    backcolor: function (c, v) { wrapSpan(c, "background-color: " + v + ";"); },
    fontname: function (c, v) { wrapSpan(c, "font-family: " + v + ";"); },
    fontsize: function (c, v) { var sizes = ["x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large"]; wrapSpan(c, "font-size: " + (sizes[(v | 0) - 1] || "medium") + ";"); },
    createlink: function (c, v) {
      var r = c.range;
      if (r.collapsed) return;
      var nodes = isolate(r, c.host);
      nodes.forEach(function (t) { var a = doc.createElement("a"); a.setAttribute("href", String(v)); t.parentNode.insertBefore(a, t); a.appendChild(t); });
      if (nodes.length) setSel(nodes[0], 0, nodes[nodes.length - 1], nodes[nodes.length - 1].data.length);
    },
    unlink: function (c) {
      var nodes = c.range.collapsed ? [canon(c.range._sc, c.range._so)[0]] : isolate(c.range, c.host);
      nodes.forEach(function (t) { for (var e = t.parentNode; e && e !== c.host; e = e.parentNode) if (e.nodeName === "A") { liftOut(t, e); break; } });
    }
  };
  // commands that edit nothing: they change a setting
  var settingsCommands = {
    defaultparagraphseparator: function (v) { v = String(v).toLowerCase(); if (v === "div" || v === "p") { settings.separator = v; return true; } return false; },
    stylewithcss: function (v) { settings.css = v === true || v === "true"; return true; },
    usecss: function (v) { settings.css = !(v === true || v === "true"); return true; },
    enableobjectresizing: function () { return true; },
    enableinlinetableediting: function () { return true; },
    contentreadonly: function () { return true; }
  };

  function execCommand(name, ui, value) {
    var n = String(name).toLowerCase();
    if (settingsCommands[n]) return settingsCommands[n](value);
    if (n === "selectall") { return selectAll(); }
    if (n === "copy" || n === "cut") {
      var text = selectedText();
      if (!text) return false;
      g.__ed.clipboard(text);
      if (n === "cut") { var cx0 = context(); if (cx0) return runEdit(cx0, "delete", undefined, "deleteByCut"); }
      return true;
    }
    if (n === "paste") return false;
    if (!KNOWN[n]) return false;
    var ctx = context();
    if (!ctx) return false;
    if (n === "undo" || n === "redo") return historyStep(ctx, n === "undo");
    return runEdit(ctx, n, value);
  }

  function runEdit(ctx, n, value, inputTypeOverride) {
    var inputType = inputTypeOverride || inputTypes[n] || "insertText";
    var data = (n === "inserthtml" || n === "inserttext" || n === "insertimage" || n === "createlink") ? String(value) : null;
    if (!fireInput(ctx.host, "beforeinput", inputType, data, true)) return false;
    // the page may have changed the selection while handling beforeinput
    ctx = context() || ctx;
    remember(ctx.host, typing[n] ? n : null);
    var result = commands[n](ctx, value);
    settle(ctx.host);
    fireInput(ctx.host, "input", inputType, data, false);
    return result === false ? false : true;
  }

  function historyStep(ctx, undo) {
    var host = ctx.host, s = stackOf(host);
    var from = undo ? s.undo : s.redo, to = undo ? s.redo : s.undo;
    if (!from.length) return false;
    if (!fireInput(host, "beforeinput", undo ? "historyUndo" : "historyRedo", null, true)) return false;
    to.push(snapshotOf(host));
    var snap = from.pop();
    restore(host, snap);
    s.key = null; s.at = null;
    fireInput(host, "input", undo ? "historyUndo" : "historyRedo", null, false);
    return true;
  }

  function selectAll() {
    var host = g.__ed.focused();
    var h = host || (valid(selection) ? hostOf(selection.focusNode) : null);
    if (h) { setSel(h, 0, h, h.childNodes.length); return true; }
    setSel(doc.body, 0, doc.body, doc.body.childNodes.length);
    return true;
  }

  function queryState(name) {
    var n = String(name).toLowerCase();
    var ctx = context();
    if (!ctx) return false;
    if (FORMATS[n]) return formatState(ctx, n);
    if (n === "insertunorderedlist" || n === "insertorderedlist") {
      var tn = n === "insertunorderedlist" ? "UL" : "OL";
      var blocks = selectedBlocks(ctx);
      return blocks.length > 0 && blocks.every(function (b) { return b.nodeName === "LI" && listOf(b) && listOf(b).nodeName === tn; });
    }
    if (n.indexOf("justify") === 0) {
      var want = { justifyleft: "left", justifycenter: "center", justifyright: "right", justifyfull: "justify" }[n];
      var b0 = closestBlock(canon(ctx.range._sc, ctx.range._so)[0], ctx.host);
      var align = b0.style && b0.style.textAlign;
      return align === want || (!align && want === "left");
    }
    return false;
  }
  function queryEnabled(name) {
    var n = String(name).toLowerCase();
    if (n === "selectall" || settingsCommands[n]) return true;
    if (!KNOWN[n]) return false;
    var ctx = context();
    if (n === "copy") return valid(selection) && !selection._range.collapsed;
    if (n === "paste") return !!ctx;
    if (!ctx) return false;
    if (n === "cut") return !ctx.range.collapsed;
    if (n === "undo") return stackOf(ctx.host).undo.length > 0;
    if (n === "redo") return stackOf(ctx.host).redo.length > 0;
    if (n === "outdent") {
      return selectedBlocks(ctx).some(function (b) {
        if (b.nodeName === "LI") return true;
        for (var q = b.parentNode; q && q !== ctx.host; q = q.parentNode) if (q.nodeName === "BLOCKQUOTE") return true;
        return false;
      });
    }
    return true;
  }
  function queryValue(name) {
    var n = String(name).toLowerCase();
    if (n === "defaultparagraphseparator") return settings.separator;
    var ctx = context();
    if (!ctx) return "";
    if (n === "formatblock") { var b = closestBlock(canon(ctx.range._sc, ctx.range._so)[0], ctx.host); return b === ctx.host ? "" : b.nodeName.toLowerCase(); }
    return "";
  }

  // ── what the session does for the user ────────────────────

  // moves the caret one character (dir -1 or 1), or extends the selection
  function move(dir, extend) {
    var ctx = context();
    if (!ctx) return;
    var r = ctx.range, host = ctx.host;
    var fn = selection.focusNode, fo = selection.focusOffset;
    if (!extend && !r.collapsed) {
      // the caret goes to the edge of the selection
      if (dir < 0) setCaret(r._sc, r._so); else setCaret(r._ec, r._eo);
      return;
    }
    var list = stops(host);
    if (!list.length) return;
    var i = stopIndex(list, fn, fo);
    var j = Math.max(0, Math.min(list.length - 1, i + dir));
    var s = list[j];
    if (extend) setSel(selection.anchorNode, selection.anchorOffset, s.node, s.off);
    else setCaret(s.node, s.off);
  }

  function wordBounds(t, off) {
    var s = t.data, a = off, b = off;
    function word(c) { return /[A-Za-z0-9_À-￿]/.test(c); }
    if (off >= s.length && s.length) { a = b = s.length - 1; if (!word(s.charAt(a))) { a = b = off; } else { b = a; } }
    if (a < s.length && word(s.charAt(a))) {
      while (a > 0 && word(s.charAt(a - 1))) a--;
      while (b < s.length && word(s.charAt(b))) b++;
    } else if (a < s.length) {
      // white space or punctuation: the run of it
      var sp = s.charAt(a) === " " || s.charAt(a) === NBSP;
      while (a > 0 && (s.charAt(a - 1) === " " || s.charAt(a - 1) === NBSP) === sp && !word(s.charAt(a - 1))) a--;
      while (b < s.length && (s.charAt(b) === " " || s.charAt(b) === NBSP) === sp && !word(s.charAt(b))) b++;
    }
    return [a, b];
  }

  function action(name, a, b, c, d) {
    var ctx;
    switch (name) {
      case "place": {
        var node = g.__ed.node(a);
        if (!node) return;
        var off = Math.min(b, len(node));
        if (node.nodeName === "BR" || node.nodeName === "IMG") { off = idx(node); node = node.parentNode; }
        if (c && valid(selection)) setSel(selection.anchorNode, selection.anchorOffset, node, off);
        else setCaret(node, off);
        return;
      }
      case "start": {
        var h = g.__ed.node(a);
        if (!h) return;
        var cn = canon(h, 0);
        setCaret(cn[0], cn[1]);
        return;
      }
      case "range": {
        var n1 = g.__ed.node(a), n2 = g.__ed.node(c);
        if (n1 && n2) setSel(n1, Math.min(b, len(n1)), n2, Math.min(d, len(n2)));
        return;
      }
      case "word": {
        var wn = g.__ed.node(a);
        if (!wn) return;
        if (isText(wn)) { var wb = wordBounds(wn, b); setSel(wn, wb[0], wn, wb[1]); } else setCaret(wn, b);
        return;
      }
      case "block": {
        var bn = g.__ed.node(a);
        if (!bn) return;
        var host0 = hostOf(bn);
        var blk = host0 ? closestBlock(bn, host0) : null;
        if (blk) {
          var f = firstLeaf(blk), l = lastLeaf(blk);
          if (f && l && isText(f) && isText(l)) setSel(f, 0, l, l.data.length); else setSel(blk, 0, blk, blk.childNodes.length);
        }
        return;
      }
      case "selectAll": selectAll(); return;
      case "move": move(a, !!b); return;
      case "text": {
        ctx = context();
        if (!ctx) return;
        var inputType = b || "insertText";
        if (!fireInput(ctx.host, "beforeinput", inputType, String(a), true)) return;
        ctx = context() || ctx;
        remember(ctx.host, "inserttext");
        if (!ctx.range.collapsed) deleteRange(ctx);
        typeText(contextNow(ctx), String(a));
        settle(ctx.host);
        fireInput(ctx.host, "input", inputType, String(a), false);
        return;
      }
      case "paste": {
        ctx = context();
        if (!ctx) return;
        var dt = new DataTransfer(); dt.setData("text/plain", String(a));
        var ev = new g.Event("paste", { bubbles: true, cancelable: true });
        ev.clipboardData = dt;
        ctx.host.dispatchEvent(ev);
        if (ev.defaultPrevented) return;
        ctx = context() || ctx;
        if (!fireInput(ctx.host, "beforeinput", "insertFromPaste", String(a), true)) return;
        ctx = context() || ctx;
        remember(ctx.host, null);
        if (!ctx.range.collapsed) deleteRange(ctx);
        insertPlain(contextNow(ctx), String(a), "insertFromPaste");
        settle(ctx.host);
        fireInput(ctx.host, "input", "insertFromPaste", String(a), false);
        return;
      }
      case "copy": case "cut": {
        ctx = context();
        if (!ctx || ctx.range.collapsed) return "";
        var dt2 = new DataTransfer();
        var ev2 = new g.Event(name, { bubbles: true, cancelable: true });
        ev2.clipboardData = dt2;
        ctx.host.dispatchEvent(ev2);
        var text = ev2.defaultPrevented ? dt2.getData("text/plain") : selectedText();
        if (name === "cut" && !ev2.defaultPrevented) { var cx = context(); if (cx) runEdit(cx, "delete", undefined, "deleteByCut"); }
        return text;
      }
      case "command": execCommand(a, false, b); return;
      case "enter": {
        ctx = context();
        if (!ctx) return;
        execCommand(a ? "insertLineBreak" : "insertParagraph");
        return;
      }
      case "backspace": execCommand("delete"); return;
      case "delete": execCommand("forwardDelete"); return;
      case "undo": execCommand("undo"); return;
      case "redo": execCommand("redo"); return;
    }
  }

  function DataTransfer() { this._d = {}; this.types = []; this.items = []; this.files = []; this.dropEffect = "none"; this.effectAllowed = "all"; }
  DataTransfer.prototype.getData = function (t) { return this._d[String(t).toLowerCase()] || ""; };
  DataTransfer.prototype.setData = function (t, v) { t = String(t).toLowerCase(); if (this.types.indexOf(t) < 0) this.types.push(t); this._d[t] = String(v); };
  DataTransfer.prototype.clearData = function () { this._d = {}; this.types = []; };
  if (!g.DataTransfer) g.DataTransfer = DataTransfer;

  // ── what the page sees ────────────────────────────────────

  function getSelection() { return selection; }
  hide(DP, "getSelection", getSelection);
  g.getSelection = getSelection;
  hide(DP, "createRange", function () { return new Range(); });
  hide(DP, "execCommand", function (name, ui, value) { return execCommand(name, ui, value); });
  hide(DP, "queryCommandState", function (name) { return queryState(name); });
  hide(DP, "queryCommandEnabled", function (name) { return queryEnabled(name); });
  hide(DP, "queryCommandIndeterm", function () { return false; });
  hide(DP, "queryCommandSupported", function (name) { var n = String(name).toLowerCase(); return KNOWN[n] === true || n === "selectall"; });
  hide(DP, "queryCommandValue", function (name) { return queryValue(name); });
  g.Range = Range;
  g.Selection = Selection;
  if (!g.DataTransfer) g.DataTransfer = DataTransfer;
  hide(g, "__ed_action", action);
  g.__ed.action = action;
})(globalThis);
