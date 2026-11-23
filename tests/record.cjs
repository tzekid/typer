// Generate fixtures through the same WASM engine shipped to the browser.
const fs = require('node:fs');
const path = require('node:path');
const wasm = new WebAssembly.Module(fs.readFileSync(path.join(__dirname, '../build/web/core.wasm')));

function record(seed, count = 250) {
  let saved;
  const { exports: ex } = new WebAssembly.Instance(wasm, {
    env: {
      pow: Math.pow,
      exp: Math.exp,
      js_measure: (_, size) => size * 16,
      js_result: (_, __, ptr, size) => { saved = Buffer.from(new Uint8Array(ex.memory.buffer, ptr, size)); },
    },
  });
  ex.mt_init(28, 1000);
  ex.mt_use_english();
  ex.mt_start(0, 30, 0, seed, 0);
  const ptr = ex.mt_words_ptr();
  const text = Buffer.from(ex.memory.buffer, ptr, ex.mt_input_len()).toString('utf8');
  for (const [i, char] of [...text.slice(0, count)].entries()) {
    const cp = char.codePointAt(0);
    if (ex.mt_before_insert(cp)) ex.mt_insert(1000 + i * 29900 / count, cp);
  }
  ex.mt_frame(31000);
  ex.mt_frame(31200);
  if (!saved) throw new Error('WASM did not finish the fixture');
  return saved;
}
module.exports = { record };
