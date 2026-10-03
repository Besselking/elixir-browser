// A small module with the helpers the page script uses.
export function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const key in attrs) {
    if (key === "class") el.className = attrs[key];
    else el.setAttribute(key, attrs[key]);
  }
  for (const child of children) el.append(child);
  return el;
}

export const byId = (id) => document.getElementById(id);

export function evalRpn(text) {
  const stack = [];
  const steps = [];
  for (const word of text.trim().split(/\s+/).filter(Boolean)) {
    if (["+", "-", "*", "/"].includes(word)) {
      if (stack.length < 2) throw `stack underflow at '${word}'`;
      const b = stack.shift();
      const a = stack.shift();
      stack.unshift(word === "+" ? a + b : word === "-" ? a - b : word === "*" ? a * b : a / b);
    } else if (isNaN(Number(word))) {
      throw `word '${word}' not recognised`;
    } else {
      stack.unshift(Number(word));
    }
    steps.push([`[${stack.join(", ")}]`, word]);
  }
  return steps;
}
