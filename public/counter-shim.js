// counter-shim.js — ~20 line JS bridge between the DOM and counter.wasm.
// Zig owns state. JS applies patches. That's the whole contract.

(async function () {
  const { instance } = await WebAssembly.instantiateStreaming(
    fetch("/counter.wasm"),
    {}
  );
  const wasm = instance.exports;

  const display = document.getElementById("count-value");

  function sync() {
    display.textContent = wasm.get_count();
  }

  document.getElementById("btn-inc").onclick = () => { wasm.increment(); sync(); };
  document.getElementById("btn-dec").onclick = () => { wasm.decrement(); sync(); };
  document.getElementById("btn-reset").onclick = () => { wasm.reset();     sync(); };

  sync(); // initial render
})();
