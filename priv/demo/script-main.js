import { h, byId, evalRpn } from "./script-helpers.js";

let clicks = 0;
byId("count").addEventListener("click", () => {
  clicks += 1;
  byId("count").textContent = `Clicked ${clicks} time${clicks === 1 ? "" : "s"}`;
});
byId("reset").addEventListener("click", () => {
  clicks = 0;
  byId("count").textContent = "Clicked 0 times";
});

byId("echo").addEventListener("input", (event) => {
  byId("out").textContent = event.target.value.toUpperCase();
});

byId("form").addEventListener("submit", (event) => {
  event.preventDefault();
  const log = byId("log");
  log.replaceChildren();
  try {
    for (const [stack, word] of evalRpn(byId("expr").value)) {
      log.appendChild(h("div", { class: "step" }, `${stack}   ${word}`));
    }
  } catch (error) {
    log.appendChild(h("div", { class: "error" }, String(error)));
  }
});

byId("box").addEventListener("change", (event) => {
  byId("note").hidden = !event.target.checked;
});

function renderStack() {
  const stack = byId("stack");
  for (const [left, right] of [["[1, 2, 3]", "dup"], ["[1, 1, 2, 3]", ""]]) {
    stack.append(h("span", {}, left), h("span", {}, right));
  }
}

renderStack();
