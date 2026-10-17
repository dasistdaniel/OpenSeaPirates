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
