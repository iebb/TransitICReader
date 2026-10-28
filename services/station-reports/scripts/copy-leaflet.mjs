import { cpSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";

const source = resolve("node_modules/leaflet/dist");
const destination = resolve("public/vendor/leaflet");
for (const relative of ["leaflet.js", "leaflet.css", "images/marker-icon.png", "images/marker-icon-2x.png", "images/marker-shadow.png"]) {
  const target = resolve(destination, relative);
  mkdirSync(dirname(target), { recursive: true });
  cpSync(resolve(source, relative), target);
}
