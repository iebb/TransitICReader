const mapPanel = document.querySelector("#map-panel");
const pinButtons = [...document.querySelectorAll(".pin-button")];
let map;
let markerLayer;

function ensureMap() {
  mapPanel.hidden = false;
  if (map) {
    map.invalidateSize();
    return;
  }
  map = L.map("map", { scrollWheelZoom: false }).setView([30, 115], 3);
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">OpenStreetMap contributors</a>',
  }).addTo(map);
  markerLayer = L.layerGroup().addTo(map);
  for (const button of pinButtons) {
    const latitude = Number(button.dataset.lat);
    const longitude = Number(button.dataset.lon);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) continue;
    const stationName = button.closest(".request-card")?.querySelector(".request-name")?.textContent ?? "Station";
    const title = document.createElement("strong");
    title.textContent = stationName;
    L.marker([latitude, longitude]).bindPopup(title).addTo(markerLayer);
  }
  requestAnimationFrame(() => map.invalidateSize());
}

for (const button of pinButtons) {
  button.addEventListener("click", () => {
    const latitude = Number(button.dataset.lat);
    const longitude = Number(button.dataset.lon);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return;
    ensureMap();
    map.setView([latitude, longitude], 14);
    mapPanel.scrollIntoView({ behavior: "smooth", block: "center" });
  });
}

document.querySelector("#close-map").addEventListener("click", () => { mapPanel.hidden = true; });
