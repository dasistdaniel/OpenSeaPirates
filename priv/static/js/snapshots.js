// Schnappschüsse puffern und zwischen ihnen interpolieren (Darstellung ~100 ms in der Vergangenheit)

const DELAY_MS = 100

function lerpAngle(a, b, f) {
  let d = (b - a) % (2 * Math.PI)
  if (d > Math.PI) d -= 2 * Math.PI
  if (d < -Math.PI) d += 2 * Math.PI
  return a + d * f
}

export class Snapshots {
  constructor() {
    this.list = []
  }

  push(snap) {
    snap.at = performance.now()
    this.list.push(snap)
    if (this.list.length > 8) this.list.shift()
  }

  get latest() {
    return this.list[this.list.length - 1]
  }

  // Zustand zum Zeitpunkt `now - DELAY_MS`; null solange nichts da ist
  sample(now) {
    const list = this.list
    if (list.length === 0) return null
    const rt = now - DELAY_MS
    let a = list[0], b = list[list.length - 1]
    for (let i = 0; i < list.length - 1; i++) {
      if (list[i].at <= rt && rt <= list[i + 1].at) {
        a = list[i]
        b = list[i + 1]
        break
      }
    }
    if (rt >= list[list.length - 1].at) a = b = list[list.length - 1]

    const span = b.at - a.at
    const f = span > 0 ? Math.min(Math.max((rt - a.at) / span, 0), 1) : 1
    const before = new Map(a.ships.map((s) => [s.i, s]))

    const ships = b.ships.map((sb) => {
      const sa = before.get(sb.i)
      if (!sa) return sb
      return {
        ...sb,
        x: sa.x + (sb.x - sa.x) * f,
        y: sa.y + (sb.y - sa.y) * f,
        h: lerpAngle(sa.h, sb.h, f),
      }
    })

    // Kugeln fliegen geradeaus: vom älteren Schnappschuss aus mit ihrer Geschwindigkeit fortschreiben
    const dt = Math.max(0, Math.min((rt - a.at) / 1000, 0.25))
    const balls = a.balls.map(([id, x, y, vx, vy]) => [id, x + vx * dt, y + vy * dt])

    const last = list[list.length - 1]
    return { ships, balls, loot: b.loot, ports: b.ports, w: b.w, wi: b.wi, you: b.you, me: last.me, last }
  }
}
