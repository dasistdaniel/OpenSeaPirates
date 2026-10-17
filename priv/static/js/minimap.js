// Minikarte um das eigene Schiff, Norden oben. Mausrad zoomt (±42 bis ±336 WE), Linksklick setzt einen
// Wegpunkt, Rechtsklick entfernt den nächsten. Gelände: nah aus den geladenen Chunks, weiter weg aus der
// Erinnerung bereits gesehener Gebiete (`Chunks.exploredKind`). Häfen kommen aus der Liste der bisher
// gesehenen Häfen und bleiben auch außerhalb der Serversicht sichtbar.

import { NATIONS } from "./nations.js"

const LEVELS = [42, 84, 168, 336] // sichtbare WE in jede Richtung
const CELLS = 84 // Rasterzellen je Seite
const LEVEL_KEY = "osp-minimap"
export const SPRITE_COLORS = ["#facc15", "#3b82f6", "#ef4444", "#22c55e", "#94a3b8", "#f8fafc"]

// Gelände-Farben nach Art: 0 tief, 1 flach, 2 Strand, 3 Land, -1 unbekannt
const COLORS = { "-1": [6, 16, 28], 0: [10, 54, 88], 1: [40, 120, 142], 2: [214, 196, 140], 3: [74, 128, 70] }
const HINT = "Mausrad: Zoom · Linksklick: Wegpunkt setzen · Rechtsklick: Wegpunkt entfernen"

export class Minimap {
  constructor(canvas, chunks) {
    this.canvas = canvas
    this.ctx = canvas.getContext("2d")
    this.chunks = chunks
    this.tmp = document.createElement("canvas")
    this.tmp.width = this.tmp.height = CELLS
    this.last = 0
    this.view = null // zuletzt gezeichnete Ansicht: { me, range, k, ports }
    this.level = 0
    try {
      const v = parseInt(localStorage.getItem(LEVEL_KEY), 10)
      if (v >= 0 && v < LEVELS.length) this.level = v
    } catch (_) {}

    // Rückrufe, die main.js setzt: Weltpunkt angeklickt / Rechtsklick
    this.onPick = null
    this.onRemove = null

    canvas.title = HINT
    canvas.addEventListener(
      "wheel",
      (e) => {
        e.preventDefault()
        this.zoom(e.deltaY > 0 ? 1 : -1)
      },
      { passive: false },
    )
    canvas.addEventListener("click", (e) => this.pick(e, this.onPick))
    canvas.addEventListener("contextmenu", (e) => {
      e.preventDefault()
      this.pick(e, this.onRemove)
    })
    canvas.addEventListener("mousemove", (e) => this.hover(e))
  }

  get range() {
    return LEVELS[this.level]
  }

  zoom(dir) {
    this.level = Math.min(Math.max(this.level + dir, 0), LEVELS.length - 1)
    this.last = 0 // sofort neu rechnen
    try { localStorage.setItem(LEVEL_KEY, String(this.level)) } catch (_) {}
  }

  // Mausposition → Weltpunkt der zuletzt gezeichneten Ansicht
  toWorld(e) {
    if (!this.view) return null
    const r = this.canvas.getBoundingClientRect()
    const px = ((e.clientX - r.left) / r.width) * this.canvas.width
    const py = ((e.clientY - r.top) / r.height) * this.canvas.height
    const { me, k } = this.view
    return { x: me.x + (px - this.canvas.width / 2) / k, y: me.y + (py - this.canvas.height / 2) / k, px, py }
  }

  pick(e, callback) {
    const w = this.toWorld(e)
    if (w && callback) callback(w.x, w.y, this.range)
  }

  // Tooltip: Name und Nation des Hafens unter der Maus, sonst die Bedienhinweise
  hover(e) {
    const w = this.toWorld(e)
    if (!w) return
    const { me, k, ports } = this.view
    let best = null, bestD = 10
    for (const p of ports) {
      const d = Math.hypot((p.x - me.x) * k + this.canvas.width / 2 - w.px, (p.y - me.y) * k + this.canvas.height / 2 - w.py)
      if (d < bestD) { best = p; bestD = d }
    }
    this.canvas.title = best ? `⚓ ${best.name}${NATIONS[best.nation] ? " · " + NATIONS[best.nation].name : ""}` : HINT
  }

  // Farbe einer Zelle: im Nahbereich (Stufe 0) feine Höhen, sonst die Erinnerung
  cellColor(x, y, step) {
    const { chunks } = this
    if (step <= 1) {
      const h = chunks.heightAt(x, y)
      if (h !== null) {
        const land = chunks.land
        if (h >= land + 0.1) return COLORS[3]
        if (h >= land) return COLORS[2]
        if (h >= land - 0.07) return COLORS[1]
        return COLORS[0]
      }
    }
    return COLORS[chunks.exploredKind(x, y)]
  }

  // `ports`: Liste `{ x, y, name, nation }` aller bisher gesehenen Häfen
  draw(me, ships, now, players = [], waypoints = [], ports = []) {
    if (!me) return
    const { ctx, canvas, tmp } = this
    const range = this.range
    const step = (range * 2) / CELLS // WE je Zelle

    // Gelände nur alle 250 ms neu berechnen, Schiffe und Marken jedes Mal
    if (now - this.last > 250) {
      this.last = now
      const g = tmp.getContext("2d")
      const img = g.createImageData(CELLS, CELLS)
      const d = img.data
      for (let j = 0; j < CELLS; j++) {
        for (let i = 0; i < CELLS; i++) {
          const [r, gr, b] = this.cellColor(me.x - range + (i + 0.5) * step, me.y - range + (j + 0.5) * step, step)
          const o = (j * CELLS + i) * 4
          d[o] = r; d[o + 1] = gr; d[o + 2] = b; d[o + 3] = 255
        }
      }
      g.putImageData(img, 0, 0)
    }

    ctx.imageSmoothingEnabled = false
    ctx.drawImage(tmp, 0, 0, canvas.width, canvas.height)

    const k = canvas.width / (range * 2)
    this.view = { me, range, k, ports }
    const half = canvas.width / 2
    const inside = (x, y) => x >= 0 && y >= 0 && x <= canvas.width && y <= canvas.height

    // Häfen: gut erkennbar als Quadrat in der Farbe der Nation mit weißem Rand und Anker
    for (const p of ports) {
      const x = (p.x - me.x) * k + half, y = (p.y - me.y) * k + half
      if (!inside(x, y)) continue
      const s = 11
      ctx.fillStyle = NATIONS[p.nation] ? NATIONS[p.nation].color : "#e2e8f0"
      ctx.fillRect(x - s / 2, y - s / 2, s, s)
      ctx.strokeStyle = "#ffffff"
      ctx.lineWidth = 2
      ctx.strokeRect(x - s / 2, y - s / 2, s, s)
      ctx.strokeStyle = "rgba(0,0,0,0.75)"
      ctx.lineWidth = 1
      ctx.strokeRect(x - s / 2 - 1.5, y - s / 2 - 1.5, s + 3, s + 3)
      ctx.fillStyle = "#ffffff"
      ctx.font = "700 9px sans-serif"
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      ctx.fillText("⚓", x, y + 0.5)
    }

    for (const s of ships) {
      const x = (s.x - me.x) * k + half, y = (s.y - me.y) * k + half
      if (!inside(x, y) || s.i === me.i || !s.a) continue
      ctx.beginPath()
      ctx.arc(x, y, 3, 0, 2 * Math.PI)
      ctx.fillStyle = s.kd === "hunter" ? "#ef4444" : s.kd === "merchant" ? "#e2e8f0" : SPRITE_COLORS[s.c % SPRITE_COLORS.length]
      ctx.fill()
      ctx.strokeStyle = "rgba(0,0,0,0.6)"
      ctx.lineWidth = 1
      ctx.stroke()
    }

    // Andere Spieler: außerhalb der Karte als Pfeil am Rand in ihre Richtung
    for (const p of players) {
      if (p[0] === me.i || ships.some((s) => s.i === p[0])) continue
      this.edgeMark(p[3] - me.x, p[4] - me.y, range, k, SPRITE_COLORS[p[2] % SPRITE_COLORS.length], false)
    }

    // Wegpunkte: goldene Raute, außerhalb der Karte als Pfeil am Rand
    for (const w of waypoints) this.edgeMark(w.x - me.x, w.y - me.y, range, k, "#fbbf24", true)

    // eigenes Schiff: Dreieck in Fahrtrichtung
    ctx.save()
    ctx.translate(half, half)
    ctx.rotate(me.h)
    ctx.beginPath()
    ctx.moveTo(6, 0); ctx.lineTo(-4, -4); ctx.lineTo(-4, 4); ctx.closePath()
    ctx.fillStyle = "#fbbf24"
    ctx.fill()
    ctx.strokeStyle = "#000"
    ctx.lineWidth = 1
    ctx.stroke()
    ctx.restore()

    // Maßstab: sichtbarer Umkreis
    ctx.font = "700 10px sans-serif"
    ctx.textAlign = "left"
    ctx.textBaseline = "bottom"
    ctx.fillStyle = "rgba(0,0,0,0.7)"
    ctx.fillText(`±${range} WE`, 7, canvas.height - 5)
    ctx.fillStyle = "#e2e8f0"
    ctx.fillText(`±${range} WE`, 6, canvas.height - 6)
  }

  // Marke für einen Punkt (dx, dy) relativ zum Schiff: Raute im Bild (nur `diamond`), sonst Pfeil am Rand
  edgeMark(dx, dy, range, k, color, diamond) {
    const { ctx, canvas } = this
    const half = canvas.width / 2
    const m = Math.max(Math.abs(dx), Math.abs(dy), 0.001)
    const f = Math.min(1, (range - range * 0.07) / m)
    const px = half + dx * f * k, py = half + dy * f * k
    ctx.save()
    ctx.translate(px, py)
    ctx.beginPath()
    if (diamond && f >= 1) {
      ctx.moveTo(0, -5.5); ctx.lineTo(5.5, 0); ctx.lineTo(0, 5.5); ctx.lineTo(-5.5, 0)
    } else {
      ctx.rotate(Math.atan2(dy, dx))
      ctx.moveTo(6, 0); ctx.lineTo(-4, -4.5); ctx.lineTo(-4, 4.5)
    }
    ctx.closePath()
    ctx.fillStyle = color
    ctx.fill()
    ctx.strokeStyle = "#000"
    ctx.lineWidth = 1
    ctx.stroke()
    ctx.restore()
  }
}
