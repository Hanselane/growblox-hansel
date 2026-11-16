// Build: gabungkan src/*.lua jadi satu file, buat folder rilis, dan tulis loader.lua.
//
// Hasil:
//   dist/main.lua                      bundle terbaru (buat tes & loader-local.lua)
//   releases/<hash>/main.lua           rilis permanen. Nama folder = sidik jari isi file,
//                                      jadi rilis lama TIDAK pernah ketimpa.
//   releases/windui-<hash>.lua         WindUI, juga permanen per versi
//   loader.lua                         yang di-loadstring dari GitHub; berisi ukuran + checksum
//
// Pola rilis permanen + checksum diadaptasi dari Clarissv build.mjs.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";

const pkg = JSON.parse(readFileSync("package.json", "utf8"));
const VERSION = pkg.version;
const { user, repo, branch } = pkg.github;
const BASE = `https://raw.githubusercontent.com/${user}/${repo}/${branch}/`;
// Urutan penting: modul yang dipakai modul lain ditulis duluan.
const MODULES = ["core", "net", "state", "bridge", "actions", "ui", "main"];

// Adler-32: checksum ringan. Versi Lua-nya ada di loader, hasilnya harus sama persis.
export function adler32(text) {
  const bytes = Buffer.from(text, "utf8");
  let a = 1, b = 0;
  for (const byte of bytes) { a = (a + byte) % 65521; b = (b + a) % 65521; }
  return b * 65536 + a;
}
const hash = (text) => createHash("sha1").update(text).digest("hex").slice(0, 20);
const size = (text) => Buffer.byteLength(text, "utf8");

// 1) Bundle
let main = `-- Growblox Hansel v${VERSION}. File ini HASIL BUILD; edit src/, lalu jalankan: node build.mjs\n`;
main += `local __VERSION = ${JSON.stringify(VERSION)}\nlocal __modules = {}\n`;
for (const name of MODULES) {
  const code = readFileSync(`src/${name}.lua`, "utf8");
  main += `\n-- ===== src/${name}.lua =====\n__modules[${JSON.stringify(name)}] = (function(...)\n${code}\nend)()\n`;
}
main += `\nreturn __modules.main(__modules, __VERSION)\n`;
mkdirSync("dist", { recursive: true });
writeFileSync("dist/main.lua", main);

// 2) Rilis permanen
const release = hash(main);
const windui = readFileSync("vendor/WindUI.lua", "utf8");
const files = {
  main: { path: `releases/${release}/main.lua`, text: main },
  windui: { path: `releases/windui-${hash(windui)}.lua`, text: windui },
};
for (const file of Object.values(files)) {
  if (existsSync(file.path)) {
    if (readFileSync(file.path, "utf8") !== file.text) throw new Error(`${file.path} sudah ada dengan isi berbeda`);
    continue; // rilis ini sudah pernah dibuat
  }
  mkdirSync(file.path.split("/").slice(0, -1).join("/"), { recursive: true });
  writeFileSync(file.path, file.text);
}

// 3) Loader
const entries = Object.entries(files).map(([name, f]) =>
  `    ${name} = { path = ${JSON.stringify(f.path)}, size = ${size(f.text)}, sum = ${adler32(f.text)} },`).join("\n");
const loader = readFileSync("loader.template.lua", "utf8")
  .replace("__VERSION__", VERSION)
  .replace("__BASE__", JSON.stringify(BASE))
  .replace("__RELEASE__", JSON.stringify(release))
  .replace("__FILES__", entries);
writeFileSync("loader.lua", loader);

console.log(`v${VERSION} rilis ${release} | main ${size(main)} byte | loader -> ${BASE}loader.lua`);
if (user === "USERNAME") console.log("PERINGATAN: isi github.user di package.json dengan username GitHub lo, lalu build ulang.");
