// Wegpunkte: per Mausklick gesetzte Ziele im Weltkoordinaten-System (nur lokal im Browser).
// Sie verschwinden, sobald das Schiff nahe genug heran ist.

const MAX = 5
const REACH_WE = 1.6

export class Waypoints {
  constructor() {
    this.list = [] // { x, y }
  }

  add(x, y) {
    if (this.list.length >= MAX) this.list.shift()
    this.list.push({ x, y })
  }

  // Nächsten Wegpunkt innerhalb `radius` (WE) entfernen; ohne Radius den nächsten überhaupt
  removeNear(x, y, radius = Infinity) {
    let best = -1, bestD = radius
    this.list.forEach((w, i) => {
      const d = Math.hypot(w.x - x, w.y - y)
      if (d <= bestD) { best = i; bestD = d }
    })
    if (best < 0) return false
    this.list.splice(best, 1)
    return true
  }

  // Erreichte Wegpunkte entfernen; gibt zurück, wie viele es waren
  reach(me) {
    const before = this.list.length
    this.list = this.list.filter((w) => Math.hypot(w.x - me.x, w.y - me.y) > REACH_WE)
    return before - this.list.length
  }
}
