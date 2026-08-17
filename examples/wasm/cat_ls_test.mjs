// Tiny JS runner for the mem cat/ls wasm module.
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const wasmPath = process.env.UTILZ_WASM
  ? join(process.env.RUNFILES_DIR ?? "", process.env.UTILZ_WASM)
  : process.argv[2];
if (!wasmPath) {
  console.error("usage: node cat_ls_test.mjs <cat_ls.wasm>");
  process.exit(2);
}
const bytes = await readFile(wasmPath);
const module = await WebAssembly.compile(bytes);
if (WebAssembly.Module.imports(module).length !== 0) {
  console.error("module imports a host capability");
  process.exit(1);
}
const { instance } = await WebAssembly.instantiate(module, {});
const e = instance.exports;
if (e.utilz_init() !== 0) process.exit(1);
if (e.utilz_cat() !== 0) process.exit(1);
const cat = new TextDecoder().decode(
  new Uint8Array(e.memory.buffer, e.utilz_stdout_ptr(), e.utilz_stdout_len()),
);
if (cat !== "hi\n") {
  console.error("cat mismatch", JSON.stringify(cat));
  process.exit(1);
}
if (e.utilz_ls() !== 0) process.exit(1);
const ls = new TextDecoder().decode(
  new Uint8Array(e.memory.buffer, e.utilz_stdout_ptr(), e.utilz_stdout_len()),
);
if (!ls.includes("a")) {
  console.error("ls mismatch", JSON.stringify(ls));
  process.exit(1);
}
console.log(JSON.stringify({ imports: 0, cat, ls, wasm_bytes: bytes.length }));
