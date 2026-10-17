// Minikarte: Ausschnitt ±RANGE WE um das eigene Schiff, Norden oben, aus den geladenen Chunks

const RANGE = 42 // WE in jede Richtung
export const SPRITE_COLORS = ["#facc15", "#3b82f6", "#ef4444", "#22c55e", "#94a3b8", "#f8fafc"]

export class Minimap {
  constructor(canvas, chunks) {
    this.canvas = canvas
    this.ctx = canvas.getContext("2d")
    this.chunks = chunks
    this.cells = RANGE * 2
    this.tmp = document.createElement("canvas")
    this.tmp.width = this.tmp.height = this.cells
    this.last = 0
  }

  draw(me, ships, now, players = [], waypoints = []) {
    if (!me) return
    const { ctx, canvas, tmp, cells, chunks } = this
    const land = chunks.land

    // Gelände nur alle 250 ms neu berechnen (80×80 Zellen), Schiffe jedes Mal
    if (now - this.last > 250) {
      this.last = now
      const g = tmp.getContext("2d")
      const img = g.createImageData(cells, cells)
      const d = img.data
      for (let j = 0; j < cells; j++) {
        for (let i = 0; i < cells; i++) {
          const x = me.x - RANGE + i + 0.5, y = me.y - RANGE + j + 0.5
          const h = chunks.heightAt(x, y)
          let r, gr, b
          if (h === null) { r = 6; gr = 16; b = 28 }
          else if (h >= land + 0.1) { r = 74; gr = 128; b = 70 }
          else if (h >= land) { r = 214; gr = 196; b = 140 }
          else if (h >= land - 0.07) { r = 40; gr = 120; b = 142 }
          else { r = 10; gr = 54; b = 88 }
          const o = (j * cells + i) * 4
          d[o] = r; d[o + 1] = gr; d[o + 2] = b; d[o + 3] = 255
        }
      }
      g.putImageData(img, 0, 0)
    }

    ctx.imageSmoothingEnabled = false
    ctx.drawImage(tmp, 0, 0, canvas.width, canvas.height)

    const k = canvas.width / (RANGE * 2)
    for (const s of ships) {
      const x = (s.x - me.x + RANGE) * k, y = (s.y - me.y + RANGE) * k
      if (x < 0 || y < 0 || x > canvas.width || y > canvas.height) continue
      if (s.i === me.i || !s.a) continue
      ctx.beginPath()
      ctx.arc(x, y, 3, 0, 2 * Math.PI)
      ctx.fillStyle = s.kd === "hunter" ? "#ef4444" : s.kd === "merchant" ? "#e2e8f0" : SPRITE_COLORS[s.c % SPRITE_COLORS.length]
      ctx.fill()
      ctx.strokeStyle = "rgba(0,0,0,0.6)"
      ctx.lineWidth = 1
      ctx.stroke()
    }

    // Andere Spieler: außerhalb der Karte als Pfeil am Rand in ihre Richtung
    const half = canvas.width / 2
    for (const p of players) {
      if (p[0] === me.i || ships.some((s) => s.i === p[0])) continue
      const dx = p[3] - me.x, dy = p[4] - me.y
      const m = Math.max(Math.abs(dx), Math.abs(dy), 0.001)
      const f = Math.min(1, (RANGE - 3) / m)
      const px = half + dx * f * k, py = half + dy * f * k
      ctx.save()
      ctx.translate(px, py)
      ctx.rotate(Math.atan2(dy, dx))
      ctx.beginPath()
      ctx.moveTo(6, 0); ctx.lineTo(-4, -4.5); ctx.lineTo(-4, 4.5); ctx.closePath()
      ctx.fillStyle = SPRITE_COLORS[p[2] % SPRITE_COLORS.length]
      ctx.fill()
      ctx.strokeStyle = "#000"
      ctx.lineWidth = 1
      ctx.stroke()
      ctx.restore()
    }

    // Wegpunkte: goldene Raute, außerhalb der Karte als Pfeil am Rand
    for (const w of waypoints) {
      const dx = w.x - me.x, dy = w.y - me.y
      const m = Math.max(Math.abs(dx), Math.abs(dy), 0.001)
      const f = Math.min(1, (RANGE - 3) / m)
      const px = half + dx * f * k, py = half + dy * f * k
      ctx.save()
      ctx.translate(px, py)
      if (f < 1) {
        ctx.rotate(Math.atan2(dy, dx))
        ctx.beginPath()
        ctx.moveTo(6, 0); ctx.lineTo(-4, -4.5); ctx.lineTo(-4, 4.5); ctx.closePath()
      } else {
        ctx.beginPath()
        ctx.moveTo(0, -5); ctx.lineTo(5, 0); ctx.lineTo(0, 5); ctx.lineTo(-5, 0); ctx.closePath()
      }
      ctx.fillStyle = "#fbbf24"
      ctx.fill()
      ctx.strokeStyle = "#000"
      ctx.lineWidth = 1
      ctx.stroke()
      ctx.restore()
    }

    // eigenes Schiff: Dreieck in Fahrtrichtung
    const c = canvas.width / 2
    ctx.save()
    ctx.translate(c, c)
    ctx.rotate(me.h)
    ctx.beginPath()
    ctx.moveTo(6, 0); ctx.lineTo(-4, -4); ctx.lineTo(-4, 4); ctx.closePath()
    ctx.fillStyle = "#fbbf24"
    ctx.fill()
    ctx.strokeStyle = "#000"
    ctx.lineWidth = 1
    ctx.stroke()
    ctx.restore()
  }
}
