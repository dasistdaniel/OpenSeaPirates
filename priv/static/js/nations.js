// Die fünf Nationen im Client: Namen und Farben für HUD und Meldungen (muss zu lib/osp/nations.ex passen)

export const NATIONS = {
  spain: { name: "Spanien", adjective: "spanische", color: "#e0a526" },
  england: { name: "England", adjective: "englische", color: "#d94b4b" },
  france: { name: "Frankreich", adjective: "französische", color: "#4f7fe0" },
  netherlands: { name: "Niederlande", adjective: "niederländische", color: "#ee8a2e" },
  portugal: { name: "Portugal", adjective: "portugiesische", color: "#3fae6a" },
}

// Flaggenbilder (lazy, einmal je Nation); null/"" und Unbekanntes ergeben null
const flags = {}
export function flagImage(nation) {
  if (!NATIONS[nation]) return null
  if (!flags[nation]) {
    const im = new Image()
    im.src = `/images/flags/${nation}.png`
    flags[nation] = im
  }
  const im = flags[nation]
  return im.complete && im.naturalWidth ? im : null
}

// Reihenfolge wie `Osp.Nations.all/0` (so stehen die Ruf-Werte in `me.rp`)
export const NATION_ORDER = Object.keys(NATIONS)

// Rufstufen wie `Osp.Reputation.standing/1`: Gesucht <= -40, Misstrauisch <= -10, Freund >= 30
export function standing(value) {
  if (value <= -40) return "wanted"
  if (value <= -10) return "suspicious"
  if (value >= 30) return "friend"
  return "neutral"
}

export const STANDING_LABEL = { wanted: "Gesucht", suspicious: "Misstrauisch", neutral: "Neutral", friend: "Freund" }
export const STANDING_COLOR = { wanted: "#f87171", suspicious: "#fbbf24", neutral: "#94a3b8", friend: "#86efac" }

export function signed(n) {
  return (n > 0 ? "+" : n < 0 ? "−" : "") + Math.abs(n)
}
