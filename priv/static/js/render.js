// Zeichnet die Welt: Wasser, Gelände-Chunks, Schiffe, Kielwasser, Wind-Kompass

const PI = Math.PI
const SPRITE_COLORS = ["yellow", "blue", "red", "green", "black", "white"]
const VIEW_WIDTH_WE = 26 // so viele Welteinheiten sind horizontal sichtbar
const SHIP_LEN_WE = 1.5

export const viewWidthWE = VIEW_WIDTH_WE

export class Renderer {
  constructor(canvas, chunks) {
    this.canvas = canvas
    this.ctx = canvas.getContext("2d")
    this.chunks = chunks
    this.scale = 40
    this.parts = [] // Kielwasser-Ringe
    this.lastWake = new Map()

    this.sprites = {}
    for (const c of SPRITE_COLORS) {
      const im = new Image()
      im.src = `/images/ship_${c}_0.png`
      this.sprites[c] = im
    }

    this.waves = this.makeWavePattern()
    window.addEventListener("resize", () => this.resize())
    this.resize()
  }

  resize() {
    const dpr = window.devicePixelRatio || 1
    this.canvas.width = Math.round(window.innerWidth * dpr)
    this.canvas.height = Math.round(window.innerHeight * dpr)
    this.dpr = dpr
    this.scale = this.canvas.width / VIEW_WIDTH_WE
  }

  makeWavePattern() {
    const size = 192
    const c = document.createElement("canvas")
    c.width = c.height = size
    const g = c.getContext("2d")
    let seed = 1234567
    const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296)
    g.strokeStyle = "rgba(255,255,255,0.10)"
    g.lineWidth = 2
    g.lineCap = "round"
    for (let i = 0; i < 34; i++) {
      const x = rnd() * size, y = rnd() * size, w = 10 + rnd() * 16
      g.beginPath()
      g.moveTo(x - w, y)
      g.quadraticCurveTo(x, y - 5, x + w, y)
      g.stroke()
    }
    return this.ctx.createPattern(c, "repeat")
  }

  // Weltpunkt → Bildschirm (Geräte-Pixel)
  sx(x, cam) { return (x - cam.x) * this.scale + this.canvas.width / 2 }
  sy(y, cam) { return (y - cam.y) * this.scale + this.canvas.height / 2 }

  draw(state, now) {
    const { ctx, canvas, scale } = this
    const W = canvas.width, H = canvas.height
    this.chunks.builtThisFrame = 0

    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.fillStyle = "#093860"
    ctx.fillRect(0, 0, W, H)

    if (!state) {
      this.banner("Verbinde …")
      return
    }

    const me = state.ships.find((s) => s.i === state.you)
    const cam = me ? { x: me.x, y: me.y } : { x: 0, y: 0 }

    this.drawChunks(cam)
    this.drawWaves(cam, now)
    this.drawWakes(state, now, cam)
    for (const s of state.ships) if (s !== me) this.drawShip(s, cam, false)
    if (me) this.drawShip(me, cam, true)
    this.drawCompass(state, me)
    return cam
  }

  drawChunks(cam) {
    const { ctx, canvas, scale, chunks } = this
    const size = chunks.size
    const halfW = canvas.width / 2 / scale, halfH = canvas.height / 2 / scale
    const c0x = Math.floor((cam.x - halfW) / size), c1x = Math.floor((cam.x + halfW) / size)
    const c0y = Math.floor((cam.y - halfH) / size), c1y = Math.floor((cam.y + halfH) / size)
    ctx.imageSmoothingEnabled = true

    for (let cx = c0x; cx <= c1x; cx++) {
      for (let cy = c0y; cy <= c1y; cy++) {
        const entry = chunks.get(cx, cy)
        if (!entry) continue
        const tex = chunks.texture(entry)
        if (!tex) continue
        const x = Math.floor(this.sx(cx * size, cam)), y = Math.floor(this.sy(cy * size, cam))
        const w = Math.ceil(size * scale) + 1
        ctx.drawImage(tex, x, y, w, w)
      }
    }
  }

  // Sanft treibende Wellenlinien über dem Gelände (Tiefenwirkung durch zwei Ebenen)
  drawWaves(cam, now) {
    const { ctx, canvas, scale, waves } = this
    const t = now / 1000
    for (const [k, drift] of [[1.0, 6], [0.6, -4]]) {
      const ox = -cam.x * scale * 0.5 * k + t * drift * scale * 0.05
      const oy = -cam.y * scale * 0.5 * k
      waves.setTransform(new DOMMatrix().translate(ox, oy).scale((scale / 40) * k))
      ctx.globalAlpha = 0.9
      ctx.fillStyle = waves
      ctx.fillRect(0, 0, canvas.width, canvas.height)
      ctx.globalAlpha = 1
    }
  }

  drawWakes(state, now, cam) {
    const { ctx, scale } = this
    for (const s of state.ships) {
      if (s.v > 0.4 && now - (this.lastWake.get(s.i) || 0) > 90) {
        this.lastWake.set(s.i, now)
        this.parts.push({
          x: s.x - Math.cos(s.h) * 0.45,
          y: s.y - Math.sin(s.h) * 0.45,
          born: now,
          life: 1100,
        })
      }
    }
    this.parts = this.parts.filter((p) => now - p.born < p.life)
    for (const p of this.parts) {
      const age = (now - p.born) / p.life
      ctx.beginPath()
      ctx.arc(this.sx(p.x, cam), this.sy(p.y, cam), (0.08 + age * 0.3) * scale, 0, 2 * PI)
      ctx.strokeStyle = `rgba(255,255,255,${0.45 * (1 - age)})`
      ctx.lineWidth = 2
      ctx.stroke()
    }
  }

  drawShip(s, cam, mine) {
    const { ctx, scale } = this
    const cx = this.sx(s.x, cam), cy = this.sy(s.y, cam)
    const im = this.sprites[SPRITE_COLORS[s.c % SPRITE_COLORS.length]]
    const len = SHIP_LEN_WE * scale, wid = (len * 66) / 113

    ctx.save()
    ctx.translate(cx, cy)
    ctx.rotate(s.h - PI / 2) // Sprite: Bug zeigt nach unten (+90°)
    if (im.complete) ctx.drawImage(im, -wid / 2, -len / 2, wid, len)
    else { ctx.fillStyle = "#ccc"; ctx.fillRect(-wid / 2, -len / 2, wid, len) }
    ctx.restore()

    ctx.font = `600 ${Math.round(0.26 * scale)}px sans-serif`
    ctx.textAlign = "center"
    ctx.textBaseline = "bottom"
    ctx.fillStyle = mine ? "#fde68a" : "rgba(255,255,255,0.9)"
    ctx.strokeStyle = "rgba(0,0,0,0.55)"
    ctx.lineWidth = 3
    ctx.strokeText(s.n, cx, cy - 0.75 * scale)
    ctx.fillText(s.n, cx, cy - 0.75 * scale)
  }

  // Wind-Kompass oben Mitte: Pfeil = Richtung, in die der Wind weht; Zahl = Tempobonus für den eigenen Kurs
  drawCompass(state, me) {
    const { ctx, canvas, dpr } = this
    const u = dpr
    const cx = canvas.width / 2, cy = 48 * u
    this.windA = this.windA === undefined ? state.w : this.windA
    let d = (state.w - this.windA) % (2 * PI)
    if (d > PI) d -= 2 * PI
    if (d < -PI) d += 2 * PI
    this.windA += d * 0.08

    ctx.beginPath()
    ctx.arc(cx, cy, 26 * u, 0, 2 * PI)
    ctx.fillStyle = "rgba(8,20,34,0.7)"
    ctx.fill()
    ctx.strokeStyle = "rgba(255,255,255,0.15)"
    ctx.lineWidth = 1
    ctx.stroke()

    ctx.save()
    ctx.translate(cx, cy)
    ctx.rotate(this.windA)
    ctx.strokeStyle = "#7dd3fc"
    ctx.lineWidth = 3 * u
    ctx.lineCap = "round"
    ctx.beginPath()
    ctx.moveTo(-15 * u, 0); ctx.lineTo(15 * u, 0)
    ctx.moveTo(7 * u, -7 * u); ctx.lineTo(15 * u, 0); ctx.lineTo(7 * u, 7 * u)
    ctx.stroke()
    ctx.restore()

    ctx.textAlign = "center"
    ctx.textBaseline = "top"
    ctx.font = `600 ${10 * u}px sans-serif`
    ctx.fillStyle = "#94a3b8"
    ctx.fillText("WIND", cx, cy - 40 * u)

    if (me) {
      const bonus = Math.round(40 * Math.cos(me.h - state.w))
      ctx.font = `800 ${13 * u}px sans-serif`
      ctx.fillStyle = bonus > 5 ? "#86efac" : bonus < -5 ? "#fca5a5" : "#cbd5e1"
      ctx.fillText((bonus > 0 ? "+" : "") + bonus + " %", cx, cy + 30 * u)
    }
  }

  banner(text) {
    const { ctx, canvas, dpr } = this
    ctx.fillStyle = "#e2e8f0"
    ctx.font = `700 ${24 * dpr}px sans-serif`
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    ctx.fillText(text, canvas.width / 2, canvas.height / 2)
  }
}
