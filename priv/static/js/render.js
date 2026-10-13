// Zeichnet die Welt: Wasser, Gelände-Chunks, Schiffe, Kugeln, Effekte und das HUD

const PI = Math.PI
const SPRITE_COLORS = ["yellow", "blue", "red", "green", "black", "white"]
const VIEW_WIDTH_WE = 26 // so viele Welteinheiten sind horizontal sichtbar
const SHIP_LEN_WE = 1.5
const RELOAD_MS = 1800

export class Renderer {
  constructor(canvas, chunks) {
    this.canvas = canvas
    this.ctx = canvas.getContext("2d")
    this.chunks = chunks
    this.scale = 40
    this.parts = [] // Effekte: Kielwasser, Explosionen, Zahlen, Splash
    this.feed = [] // Abschuss-Meldungen
    this.lastWake = new Map()

    this.sprites = {}
    for (const c of SPRITE_COLORS) {
      for (let n = 0; n < 3; n++) {
        const im = new Image()
        im.src = `/images/ship_${c}_${n}.png`
        this.sprites[`${c}_${n}`] = im
      }
    }
    this.expl = [1, 2, 3].map((n) => {
      const im = new Image()
      im.src = `/images/explosion${n}.png`
      return im
    })

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

  // --- Effekte von außen ------------------------------------------------------------

  effect(p) {
    this.parts.push({ born: performance.now(), ...p })
  }

  killFeed(text, mine) {
    this.feed.push({ text, mine, until: performance.now() + 5000 })
    if (this.feed.length > 5) this.feed.shift()
  }

  // Weltpunkt → Bildschirm (Geräte-Pixel)
  sx(x, cam) { return (x - cam.x) * this.scale + this.canvas.width / 2 }
  sy(y, cam) { return (y - cam.y) * this.scale + this.canvas.height / 2 }

  draw(state, now) {
    const { ctx, canvas } = this
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
    const cam = me ? { x: me.x, y: me.y } : this.lastCam || { x: 0, y: 0 }
    this.lastCam = cam

    this.drawChunks(cam)
    this.drawWaves(cam, now)
    this.drawLoot(state, cam, now)
    this.drawWakes(state, now, cam)
    for (const s of state.ships) if (s !== me && s.a) this.drawShip(s, cam, false, now)
    if (me && me.a) this.drawShip(me, cam, true, now)
    this.drawBalls(state, cam)
    this.drawParts(now, cam)
    this.drawCompass(state, me)
    this.drawHud(state, me, now)
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
    for (const s of state.ships) {
      if (s.a && s.v > 0.4 && now - (this.lastWake.get(s.i) || 0) > 90) {
        this.lastWake.set(s.i, now)
        this.parts.push({
          t: "wake",
          x: s.x - Math.cos(s.h) * 0.45,
          y: s.y - Math.sin(s.h) * 0.45,
          born: now,
          life: 1100,
        })
      }
    }
  }

  // Beute: Münzhaufen, die sanft auf dem Wasser treiben; Größe nach Menge
  drawLoot(state, cam, now) {
    const { ctx, scale } = this
    for (const [id, x, y, gold] of state.loot || []) {
      const bob = Math.sin(now / 400 + id) * 0.04
      const cx = this.sx(x, cam), cy = this.sy(y + bob, cam)
      const r = (0.17 + Math.min(gold, 100) / 100 * 0.1) * scale
      for (let k = 0; k < 3; k++) {
        ctx.beginPath()
        ctx.ellipse(cx + (k - 1) * r * 0.7, cy + (k % 2) * r * 0.4, r * 0.8, r * 0.55, 0, 0, 2 * PI)
        ctx.fillStyle = k === 1 ? "#fbbf24" : "#f59e0b"
        ctx.fill()
        ctx.lineWidth = 1.5
        ctx.strokeStyle = "#92400e"
        ctx.stroke()
      }
      ctx.font = `700 ${Math.round(0.24 * scale)}px sans-serif`
      ctx.textAlign = "center"
      ctx.textBaseline = "bottom"
      ctx.fillStyle = "#fde68a"
      ctx.strokeStyle = "rgba(0,0,0,0.6)"
      ctx.lineWidth = 3
      ctx.strokeText(gold, cx, cy - r)
      ctx.fillText(gold, cx, cy - r)
    }
  }

  drawBalls(state, cam) {
    const { ctx, scale } = this
    for (const [, x, y] of state.balls) {
      ctx.beginPath()
      ctx.arc(this.sx(x, cam), this.sy(y, cam), 0.085 * scale, 0, 2 * PI)
      ctx.fillStyle = "#0f172a"
      ctx.fill()
      ctx.lineWidth = 1.5
      ctx.strokeStyle = "#e2e8f0"
      ctx.stroke()
    }
  }

  drawShip(s, cam, mine, now) {
    const { ctx, scale } = this
    const cx = this.sx(s.x, cam), cy = this.sy(s.y, cam)
    const ratio = Math.max(s.hp / s.mh, 0)
    const state = ratio > 0.66 ? 0 : ratio > 0.33 ? 1 : 2
    const im = this.sprites[`${SPRITE_COLORS[s.c % SPRITE_COLORS.length]}_${state}`]
    const len = SHIP_LEN_WE * scale, wid = (len * 66) / 113

    ctx.save()
    ctx.translate(cx, cy)
    if (s.iv && Math.floor(now / 120) % 2) ctx.globalAlpha = 0.45
    ctx.rotate(s.h - PI / 2) // Sprite: Bug zeigt nach unten (+90°)
    if (im.complete) ctx.drawImage(im, -wid / 2, -len / 2, wid, len)
    else { ctx.fillStyle = "#ccc"; ctx.fillRect(-wid / 2, -len / 2, wid, len) }
    ctx.restore()

    // Name und Lebensbalken
    ctx.font = `600 ${Math.round(0.26 * scale)}px sans-serif`
    ctx.textAlign = "center"
    ctx.textBaseline = "bottom"
    ctx.fillStyle = mine ? "#fde68a" : s.kd === "hunter" ? "#fca5a5" : s.kd === "merchant" ? "#cbd5e1" : "rgba(255,255,255,0.92)"
    ctx.strokeStyle = "rgba(0,0,0,0.55)"
    ctx.lineWidth = 3
    ctx.strokeText(s.n, cx, cy - 0.95 * scale)
    ctx.fillText(s.n, cx, cy - 0.95 * scale)
    const bw = 1.0 * scale, bh = 0.1 * scale
    ctx.fillStyle = "rgba(0,0,0,0.5)"
    ctx.fillRect(cx - bw / 2, cy - 0.9 * scale, bw, bh)
    ctx.fillStyle = ratio > 0.5 ? "#4ade80" : ratio > 0.25 ? "#fbbf24" : "#f87171"
    ctx.fillRect(cx - bw / 2, cy - 0.9 * scale, bw * ratio, bh)
  }

  drawParts(now, cam) {
    const { ctx, scale } = this
    this.parts = this.parts.filter((p) => now - p.born < p.life)
    for (const p of this.parts) {
      const age = (now - p.born) / p.life
      const cx = this.sx(p.x, cam), cy = this.sy(p.y, cam)
      if (p.t === "wake") {
        ctx.beginPath()
        ctx.arc(cx, cy, (0.08 + age * 0.3) * scale, 0, 2 * PI)
        ctx.strokeStyle = `rgba(255,255,255,${0.45 * (1 - age)})`
        ctx.lineWidth = 2
        ctx.stroke()
      } else if (p.t === "expl") {
        const im = this.expl[Math.min(Math.floor(age * 2.99), 2)]
        const size = p.size * scale * (0.6 + 0.6 * age)
        ctx.globalAlpha = 1 - age * age
        if (im.complete) ctx.drawImage(im, cx - size / 2, cy - size / 2, size, size)
        ctx.globalAlpha = 1
      } else if (p.t === "ring") {
        ctx.beginPath()
        ctx.arc(cx, cy, (0.1 + age * 0.3) * scale, 0, 2 * PI)
        ctx.strokeStyle = `rgba(255,255,255,${0.6 * (1 - age)})`
        ctx.lineWidth = 2
        ctx.stroke()
      } else if (p.t === "text") {
        ctx.font = `800 ${Math.round(0.34 * scale)}px sans-serif`
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        ctx.globalAlpha = 1 - age
        ctx.fillStyle = p.color
        ctx.fillText(p.text, cx, cy - age * 0.9 * scale)
        ctx.globalAlpha = 1
      }
    }
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

  // Eigenes Schiff: Leben, Nachladen, Abschüsse; Meldungen; Versenkt-Banner
  drawHud(state, me, now) {
    const { ctx, canvas, dpr } = this
    const u = dpr
    const mine = state.me
    if (!me || !mine) return

    const W = canvas.width, H = canvas.height
    const bx = W / 2 - 150 * u, by = H - 70 * u
    ctx.fillStyle = "rgba(8,20,34,0.72)"
    ctx.fillRect(bx - 8 * u, by - 12 * u, 316 * u, 76 * u)

    const ratio = Math.max(me.hp / me.mh, 0)
    ctx.fillStyle = "rgba(255,255,255,0.12)"
    ctx.fillRect(bx, by, 300 * u, 14 * u)
    ctx.fillStyle = ratio > 0.5 ? "#4ade80" : ratio > 0.25 ? "#fbbf24" : "#f87171"
    ctx.fillRect(bx, by, 300 * u * ratio, 14 * u)
    ctx.font = `700 ${11 * u}px sans-serif`
    ctx.textAlign = "left"
    ctx.textBaseline = "middle"
    ctx.fillStyle = "#0f172a"
    ctx.fillText(Math.ceil(me.hp) + " / " + me.mh + " HP", bx + 6 * u, by + 7.5 * u)

    const reload = (label, ms, x) => {
      const f = 1 - Math.min(ms / RELOAD_MS, 1)
      ctx.fillStyle = "rgba(255,255,255,0.12)"
      ctx.fillRect(x, by + 24 * u, 144 * u, 12 * u)
      ctx.fillStyle = f >= 1 ? "#fbbf24" : "#64748b"
      ctx.fillRect(x, by + 24 * u, 144 * u * f, 12 * u)
      ctx.fillStyle = "#f8fafc"
      ctx.font = `700 ${10 * u}px sans-serif`
      ctx.textAlign = "left"
      ctx.fillText(label, x + 5 * u, by + 30.5 * u)
    }
    reload("Q  links", mine.rl, bx)
    reload("E  rechts", mine.rr, bx + 156 * u)

    ctx.textAlign = "left"
    ctx.fillStyle = "#fbbf24"
    ctx.font = `800 ${14 * u}px sans-serif`
    ctx.fillText(`🪙 ${mine.g}`, bx, by + 50 * u)
    ctx.textAlign = "right"
    ctx.fillStyle = "#cbd5e1"
    ctx.font = `700 ${12 * u}px sans-serif`
    ctx.fillText(`Abschüsse ${mine.k}  ·  Tode ${mine.d}`, bx + 300 * u, by + 50 * u)

    // Abschuss-Meldungen oben rechts
    this.feed = this.feed.filter((f) => f.until > now)
    ctx.font = `700 ${14 * u}px sans-serif`
    ctx.textAlign = "right"
    this.feed.forEach((f, n) => {
      ctx.fillStyle = f.mine ? "#fde68a" : "#cbd5e1"
      ctx.fillText(f.text, W - 16 * u, 24 * u + n * 22 * u)
    })

    if (!me.a) {
      ctx.textAlign = "center"
      ctx.fillStyle = "#fca5a5"
      ctx.font = `800 ${34 * u}px sans-serif`
      ctx.fillText("Versenkt", W / 2, H / 2 - 10 * u)
      ctx.font = `600 ${16 * u}px sans-serif`
      ctx.fillStyle = "#e2e8f0"
      const left = Math.max(Math.ceil((mine.rs - (now - state.last.at)) / 1000), 0)
      ctx.fillText(`Neustart in ${left} s`, W / 2, H / 2 + 24 * u)
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
