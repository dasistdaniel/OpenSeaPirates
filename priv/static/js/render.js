// Zeichnet die Welt: Wasser, Gelände-Chunks, Schiffe, Kugeln, Effekte und das HUD

const PI = Math.PI
import { SPRITE_COLORS as PLAYER_COLORS } from "./minimap.js"
import { NATIONS, flagImage } from "./nations.js"

const SPRITE_COLORS = ["yellow", "blue", "red", "green", "black", "white"]
const VIEW_WIDTH_WE = 26 // Standard: so viele Welteinheiten sind horizontal sichtbar
const VIEW_MIN = 12 // Zoom: kleinste und größte sichtbare Breite (der Server schickt ~45 WE Umkreis)
const VIEW_MAX = 44
const ZOOM_KEY = "osp-zoom"
const WE_PER_PX = 1.5 / 113 // Maßstab der Schiffsbilder
const RELOAD_MS = 3000

// Deterministischer Zufall 0..1 aus zwei ganzen Zahlen (für Wellenkämme)
function hash2(a, b) {
  let h = Math.imul(a | 0, 374761393) + Math.imul(b | 0, 668265263)
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296
}

function loadZoom() {
  try {
    const v = parseFloat(localStorage.getItem(ZOOM_KEY))
    if (v >= VIEW_MIN && v <= VIEW_MAX) return v
  } catch (_) {}
  return VIEW_WIDTH_WE
}

export class Renderer {
  constructor(canvas, chunks) {
    this.canvas = canvas
    this.ctx = canvas.getContext("2d")
    this.chunks = chunks
    this.scale = 40
    this.view = { cur: loadZoom(), target: loadZoom() } // sichtbare Breite in WE, weich nachgeführt
    this.parts = [] // Effekte: Kielwasser, Explosionen, Zahlen, Splash
    this.feed = [] // Abschuss-Meldungen
    this.lastWake = new Map()
    this.lastSmoke = new Map()

    this.sprites = {} // "klasse_farbe" -> Image (lazy)
    this.tiles = {}
    for (const n of ["tile_13", "tile_60"]) {
      const im = new Image()
      im.src = `/images/tiles/${n}.png`
      this.tiles[n] = im
    }
    this.expl = [1, 2, 3].map((n) => {
      const im = new Image()
      im.src = `/images/explosion${n}.png`
      return im
    })

    window.addEventListener("resize", () => this.resize())
    this.resize()
  }

  resize() {
    const dpr = window.devicePixelRatio || 1
    this.canvas.width = Math.round(window.innerWidth * dpr)
    this.canvas.height = Math.round(window.innerHeight * dpr)
    this.dpr = dpr
    this.scale = this.canvas.width / this.view.cur
  }

  // --- Effekte von außen ------------------------------------------------------------

  effect(p) {
    this.parts.push({ born: performance.now(), ...p })
  }

  killFeed(text, mine) {
    this.feed.push({ text, mine, until: performance.now() + 5000 })
    if (this.feed.length > 5) this.feed.shift()
  }

  // Mausrad: `factor` > 1 zoomt heraus (mehr Welt sichtbar), < 1 hinein
  zoomBy(factor) {
    this.view.target = Math.min(Math.max(this.view.target * factor, VIEW_MIN), VIEW_MAX)
    try { localStorage.setItem(ZOOM_KEY, String(this.view.target)) } catch (_) {}
  }

  // Bildschirmpunkt (CSS-Pixel, z. B. clientX/Y) → Weltpunkt um die letzte Kamera; null ohne Kamera
  worldAt(clientX, clientY) {
    const cam = this.lastCam
    if (!cam) return null
    const { canvas, scale, dpr } = this
    return {
      x: cam.x + (clientX * dpr - canvas.width / 2) / scale,
      y: cam.y + (clientY * dpr - canvas.height / 2) / scale,
    }
  }

  // Weltpunkt → Bildschirm (Geräte-Pixel)
  sx(x, cam) { return (x - cam.x) * this.scale + this.canvas.width / 2 }
  sy(y, cam) { return (y - cam.y) * this.scale + this.canvas.height / 2 }

  draw(state, now) {
    const { ctx, canvas } = this
    const W = canvas.width, H = canvas.height
    this.chunks.builtThisFrame = 0

    // Zoom weich nachführen
    if (Math.abs(this.view.target - this.view.cur) > 0.01) {
      this.view.cur += (this.view.target - this.view.cur) * 0.2
      this.scale = W / this.view.cur
    }

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
    this.drawPorts(state, cam, now)
    this.drawLoot(state, cam, now)
    this.drawWakes(state, now, cam)
    this.drawParts(now, cam, true)
    for (const s of state.ships) if (s !== me && s.a) this.drawShip(s, cam, false, now)
    if (me && me.a) this.drawShip(me, cam, true, now)
    this.drawBalls(state, cam)
    this.drawParts(now, cam)
    this.drawWaypoints(me, cam, now)
    this.drawPlayerPointers(state, me, cam)
    this.drawCompass(state, me)
    this.drawHud(state, me, now)
  }

  // Pfeile am Bildrand zu Spielern außerhalb des Bildschirms: Name und Entfernung in WE
  drawPlayerPointers(state, me, cam) {
    if (!me || !this.players) return
    const { ctx, canvas, dpr } = this
    const live = new Map(state.ships.map((s) => [s.i, s]))
    const W = canvas.width, H = canvas.height
    const inset = 46 * dpr
    for (const [id, name, color, px, py] of this.players) {
      if (id === state.you) continue
      const s = live.get(id)
      const x = s ? s.x : px, y = s ? s.y : py
      const sx = this.sx(x, cam), sy = this.sy(y, cam)
      if (sx > inset && sx < W - inset && sy > inset && sy < H - inset) continue
      this.edgeArrow(sx, sy, PLAYER_COLORS[color % PLAYER_COLORS.length], `${name} · ${Math.round(Math.hypot(x - me.x, y - me.y))}`)
    }
  }

  // Pfeil am Bildrand in Richtung des Bildschirmpunkts (sx, sy) mit Beschriftung
  edgeArrow(sx, sy, fill, label) {
    const { ctx, canvas, dpr } = this
    const W = canvas.width, H = canvas.height
    const inset = 46 * dpr
    const dx = sx - W / 2, dy = sy - H / 2
    const f = Math.min((W / 2 - inset) / Math.max(Math.abs(dx), 1), (H / 2 - inset) / Math.max(Math.abs(dy), 1))
    const ax = W / 2 + dx * f, ay = H / 2 + dy * f
    ctx.save()
    ctx.translate(ax, ay)
    ctx.rotate(Math.atan2(dy, dx))
    ctx.beginPath()
    ctx.moveTo(13 * dpr, 0); ctx.lineTo(-8 * dpr, -9 * dpr); ctx.lineTo(-8 * dpr, 9 * dpr); ctx.closePath()
    ctx.fillStyle = fill
    ctx.fill()
    ctx.strokeStyle = "rgba(0,0,0,0.7)"
    ctx.lineWidth = 2 * dpr
    ctx.stroke()
    ctx.restore()
    ctx.font = `700 ${Math.round(12 * dpr)}px sans-serif`
    ctx.textAlign = dx > 0 ? "right" : "left"
    ctx.textBaseline = "middle"
    const tx = ax + (dx > 0 ? -18 : 18) * dpr
    ctx.strokeStyle = "rgba(0,0,0,0.7)"
    ctx.lineWidth = 3 * dpr
    ctx.strokeText(label, tx, ay)
    ctx.fillStyle = "#f1f5f9"
    ctx.fillText(label, tx, ay)
  }

  // Wegpunkte: Raute mit Ring auf dem Bild, sonst Pfeil am Rand; zum nächsten führt eine gestrichelte Linie
  drawWaypoints(me, cam, now) {
    if (!me || !this.waypoints) return
    const { ctx, canvas, scale, dpr } = this
    const W = canvas.width, H = canvas.height
    const inset = 46 * dpr
    const mx = this.sx(me.x, cam), my = this.sy(me.y, cam)
    this.waypoints.list.forEach((w, i) => {
      const sx = this.sx(w.x, cam), sy = this.sy(w.y, cam)
      const dist = Math.round(Math.hypot(w.x - me.x, w.y - me.y))
      if (i === 0) {
        ctx.save()
        ctx.setLineDash([10 * dpr, 12 * dpr])
        ctx.lineDashOffset = -now / 40
        ctx.beginPath()
        ctx.moveTo(mx, my)
        ctx.lineTo(sx, sy)
        ctx.strokeStyle = "rgba(251,191,36,0.4)"
        ctx.lineWidth = 2 * dpr
        ctx.stroke()
        ctx.restore()
      }
      if (sx > inset && sx < W - inset && sy > inset && sy < H - inset) {
        const pulse = 0.5 + 0.5 * Math.sin(now / 300)
        ctx.beginPath()
        ctx.arc(sx, sy, (0.35 + pulse * 0.15) * scale, 0, 2 * PI)
        ctx.strokeStyle = `rgba(251,191,36,${0.35 + pulse * 0.3})`
        ctx.lineWidth = 2 * dpr
        ctx.stroke()
        const r = 0.16 * scale
        ctx.beginPath()
        ctx.moveTo(sx, sy - r); ctx.lineTo(sx + r, sy); ctx.lineTo(sx, sy + r); ctx.lineTo(sx - r, sy); ctx.closePath()
        ctx.fillStyle = "#fbbf24"
        ctx.fill()
        ctx.strokeStyle = "rgba(0,0,0,0.7)"
        ctx.stroke()
        ctx.font = `700 ${Math.round(12 * dpr)}px sans-serif`
        ctx.textAlign = "center"
        ctx.textBaseline = "top"
        ctx.lineWidth = 3 * dpr
        ctx.strokeText(String(dist), sx, sy + 0.5 * scale)
        ctx.fillStyle = "#fde68a"
        ctx.fillText(String(dist), sx, sy + 0.5 * scale)
      } else {
        this.edgeArrow(sx, sy, "#fbbf24", `Ziel · ${dist}`)
      }
    })
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

  // Wasser: breite Dünungsbänder (hell/dunkel) laufen mit dem Wind, darauf Wellenkämme, die in der
  // Weltkoordinate verankert sind, aufkommen, mit dem Wind wandern und wieder verschwinden.
  drawWaves(cam, now) {
    const { ctx, canvas, scale } = this
    const t = now / 1000
    const wa = this.windA === undefined ? 0 : this.windA
    const wx = Math.cos(wa), wy = Math.sin(wa)
    const W = canvas.width, H = canvas.height

    // Dünung: Bänder quer zur Windrichtung
    const diag = Math.hypot(W, H) / scale // Bildschirmdiagonale in WE
    const period = 11
    const along = cam.x * wx + cam.y * wy - t * 0.7 // wandert mit dem Wind
    ctx.save()
    ctx.translate(W / 2, H / 2)
    ctx.rotate(wa)
    const first = Math.floor((along - diag / 2) / period) - 1
    const last = Math.ceil((along + diag / 2) / period) + 1
    for (let k = first; k <= last; k++) {
      const x = (k * period - along) * scale
      const g = ctx.createLinearGradient(x, 0, x + period * scale, 0)
      g.addColorStop(0, "rgba(255,255,255,0)")
      g.addColorStop(0.5, "rgba(190,230,255,0.055)")
      g.addColorStop(1, "rgba(255,255,255,0)")
      ctx.fillStyle = g
      ctx.fillRect(x, -diag * scale, period * scale, diag * 2 * scale)
    }
    ctx.restore()

    // Wellenkämme: pro Rasterzelle ein Kamm mit eigener Phase
    const cell = 1.8
    const halfW = W / 2 / scale + 1, halfH = H / 2 / scale + 1
    ctx.lineCap = "round"
    for (let ci = Math.floor((cam.x - halfW) / cell); ci <= Math.floor((cam.x + halfW) / cell); ci++) {
      for (let cj = Math.floor((cam.y - halfH) / cell); cj <= Math.floor((cam.y + halfH) / cell); cj++) {
        const h = hash2(ci, cj)
        if (h < 0.35) continue // nicht jede Zelle hat einen Kamm
        const h2 = hash2(cj + 91, ci - 17), h3 = hash2(ci * 3 + 5, cj * 7 - 2)
        const phase = (t * (0.11 + h2 * 0.07) + h3) % 1 // Lebenszyklus 0..1
        const alpha = Math.sin(phase * PI) ** 2 * 0.3
        if (alpha < 0.01) continue
        const drift = phase * 1.4 - 0.7
        const px = (ci + h2) * cell + wx * drift
        const py = (cj + h3) * cell + wy * drift
        const len = 0.35 + h * 0.5
        const sx = this.sx(px, cam), sy = this.sy(py, cam)
        // Kamm quer zur Windrichtung, in der Mitte zum Wind hin gewölbt
        const nx = -wy, ny = wx
        // nur auf Wasser: Mitte und beide Enden müssen bekannt und unter der Küste liegen
        const shore = this.chunks.land - 0.02
        let wet = true
        for (const k of [-1, 0, 1]) {
          const hh = this.chunks.heightAt(px + nx * len * k, py + ny * len * k)
          if (hh === null || hh >= shore) { wet = false; break }
        }
        if (!wet) continue
        const half = len * scale
        ctx.beginPath()
        ctx.moveTo(sx - nx * half, sy - ny * half)
        ctx.quadraticCurveTo(sx + wx * 0.22 * scale, sy + wy * 0.22 * scale, sx + nx * half, sy + ny * half)
        ctx.strokeStyle = `rgba(235,247,255,${alpha})`
        ctx.lineWidth = Math.max(1.5, 0.045 * scale)
        ctx.stroke()
      }
    }
  }

  drawWakes(state, now, cam) {
    // Rauch aus angeschlagenen Schiffen: ab halber Gesundheit grau, unter einem Viertel dicht und schwarz;
    // er treibt mit dem Wind
    const wx = Math.cos(state.w), wy = Math.sin(state.w)
    for (const s of state.ships) {
      if (!s.a || s.mh <= 0) continue
      const ratio = s.hp / s.mh
      if (ratio >= 0.5) continue
      const every = ratio < 0.25 ? 70 : 150
      if (now - (this.lastSmoke.get(s.i) || 0) < every) continue
      this.lastSmoke.set(s.i, now)
      this.parts.push({
        t: "smoke",
        x: s.x + (Math.random() - 0.5) * 0.3,
        y: s.y + (Math.random() - 0.5) * 0.3,
        vx: wx * 0.35,
        vy: wy * 0.35 - 0.12,
        born: now,
        life: 1500 + Math.random() * 700,
        dark: ratio < 0.25,
      })
    }

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

  // Bild je Klasse, Farbe und Segelstufe (gerafft/Beisegel: nur die Segel sind kleiner/größer);
  // solange die Variante lädt, dient das Bild mit vollen Segeln
  sprite(cl, color, sail) {
    const base = `${cl}_${SPRITE_COLORS[color % SPRITE_COLORS.length]}`
    if (sail === "reefed" || sail === "studding") {
      const v = this.spriteFile(`${base}_${sail}`)
      if (v.complete && v.naturalWidth) return v
    }
    return this.spriteFile(base)
  }

  spriteFile(key) {
    let im = this.sprites[key]
    if (!im) {
      im = new Image()
      im.src = `/images/ships/${key}.png`
      this.sprites[key] = im
    }
    return im
  }

  drawShip(s, cam, mine, now) {
    const { ctx, scale } = this
    const cx = this.sx(s.x, cam), cy = this.sy(s.y, cam)
    const ratio = Math.max(s.hp / s.mh, 0)
    const im = this.sprite(s.cl, s.c, s.sa)

    ctx.save()
    ctx.translate(cx, cy)
    if (s.iv && Math.floor(now / 120) % 2) ctx.globalAlpha = 0.45
    ctx.rotate(s.h - PI / 2) // Sprite: Bug zeigt nach unten (+90°)
    // leichtes Schaukeln auf der Dünung, je Schiff versetzt
    const ph = (typeof s.i === "number" ? s.i : String(s.i).length) * 1.7
    ctx.rotate(Math.sin(now / 780 + ph) * 0.03)
    const bob = 1 + Math.sin(now / 1100 + ph) * 0.012
    ctx.scale(bob, bob)
    if (im.complete && im.naturalWidth) {
      const w = im.naturalWidth * WE_PER_PX * scale, h = im.naturalHeight * WE_PER_PX * scale
      ctx.drawImage(im, -w / 2, -h / 2, w, h)
    } else {
      ctx.fillStyle = "#ccc"
      ctx.fillRect(-0.3 * scale, -0.7 * scale, 0.6 * scale, 1.4 * scale)
    }
    ctx.restore()

    const top = (s.rd || 0.36) * scale + 0.55 * scale // Höhe über dem Schiff für Name und Balken

    if (s.sl) {
      ctx.beginPath()
      ctx.arc(cx, cy, 0.85 * scale, 0, 2 * PI)
      ctx.strokeStyle = "rgba(125,211,252,0.8)"
      ctx.setLineDash([3, 5])
      ctx.lineWidth = 2
      ctx.stroke()
      ctx.setLineDash([])
    }
    if (s.bu) {
      ctx.font = `${Math.round(0.5 * scale)}px sans-serif`
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      ctx.fillText("🔥", cx + Math.sin(now / 90) * 4, cy - 0.2 * scale)
    }

    // Name und Lebensbalken
    ctx.font = `600 ${Math.round(0.26 * scale)}px sans-serif`
    ctx.textAlign = "center"
    ctx.textBaseline = "bottom"
    ctx.fillStyle = mine ? "#fde68a" : s.kd === "hunter" ? "#fca5a5" : s.kd === "merchant" ? "#cbd5e1" : "rgba(255,255,255,0.92)"
    ctx.strokeStyle = "rgba(0,0,0,0.55)"
    ctx.lineWidth = 3
    this.labelWithFlag(s.n, s.na, cx, cy - top, Math.round(0.26 * scale))
    const bw = 1.0 * scale, bh = 0.1 * scale
    ctx.fillStyle = "rgba(0,0,0,0.5)"
    ctx.fillRect(cx - bw / 2, cy - top + 0.05 * scale, bw, bh)
    ctx.fillStyle = ratio > 0.5 ? "#4ade80" : ratio > 0.25 ? "#fbbf24" : "#f87171"
    ctx.fillRect(cx - bw / 2, cy - top + 0.05 * scale, bw * ratio, bh)
  }

  // Text (mit der Füllfarbe/Kontur, die der Aufrufer gesetzt hat) mittig über (x, y), die Flagge der
  // Nation links davor, falls bekannt und geladen. `size` ist die Schrifthöhe in Pixeln.
  labelWithFlag(text, nation, x, y, size) {
    const { ctx } = this
    const flag = flagImage(nation)
    ctx.textAlign = "left"
    ctx.textBaseline = "bottom"
    const textW = ctx.measureText(text).width
    const flagH = size, flagW = flag ? (flag.naturalWidth / flag.naturalHeight) * flagH : 0
    const gap = flag ? size * 0.3 : 0
    const left = x - (flagW + gap + textW) / 2
    if (flag) {
      ctx.imageSmoothingEnabled = false
      ctx.drawImage(flag, left, y - flagH, flagW, flagH)
    }
    ctx.strokeText(text, left + flagW + gap, y)
    ctx.fillText(text, left + flagW + gap, y)
  }

  // Häfen: Schutzzone, Steg zur Küste, Turm, Name
  drawPorts(state, cam, now) {
    const { ctx, scale } = this
    for (const [, x, y, name, land, nation] of state.ports || []) {
      const cx = this.sx(x, cam), cy = this.sy(y, cam)

      ctx.beginPath()
      ctx.arc(cx, cy, 3.5 * scale, 0, 2 * PI)
      ctx.fillStyle = "rgba(74,222,128,0.07)"
      ctx.fill()
      ctx.setLineDash([8, 8])
      ctx.lineDashOffset = -now / 60
      ctx.strokeStyle = "rgba(134,239,172,0.55)"
      ctx.lineWidth = 2
      ctx.stroke()
      ctx.setLineDash([])

      // Steg (zwei Brückenstücke) und Turm Richtung Land
      const place = (img, dist, size, rot) => {
        if (!img.complete || !img.naturalWidth) return
        ctx.save()
        ctx.translate(cx + Math.cos(land) * dist * scale, cy + Math.sin(land) * dist * scale)
        ctx.rotate(land + rot)
        ctx.drawImage(img, (-size * scale) / 2, (-size * scale) / 2, size * scale, size * scale)
        ctx.restore()
      }
      place(this.tiles.tile_60, 1.7, 1.15, 0)
      place(this.tiles.tile_60, 2.8, 1.15, 0)
      place(this.tiles.tile_13, 4.0, 1.5, 0)

      ctx.font = `700 ${Math.round(0.34 * scale)}px sans-serif`
      ctx.fillStyle = "#fef3c7"
      ctx.strokeStyle = "rgba(0,0,0,0.65)"
      ctx.lineWidth = 4
      this.labelWithFlag("⚓ " + name, nation, cx, cy - 1.1 * scale, Math.round(0.34 * scale))
    }
  }

  // under = true: nur Teile, die unter den Schiffen liegen (Kielwasser); sonst alle übrigen
  drawParts(now, cam, under = false) {
    const { ctx, scale } = this
    if (!under) this.parts = this.parts.filter((p) => now - p.born < p.life)
    for (const p of this.parts) {
      if ((p.t === "wake") !== under || now - p.born >= p.life) continue
      const age = (now - p.born) / p.life
      const cx = this.sx(p.x, cam), cy = this.sy(p.y, cam)
      if (p.t === "wake") {
        ctx.beginPath()
        ctx.arc(cx, cy, (0.08 + age * 0.3) * scale, 0, 2 * PI)
        ctx.strokeStyle = `rgba(255,255,255,${0.45 * (1 - age)})`
        ctx.lineWidth = 2
        ctx.stroke()
      } else if (p.t === "smoke") {
        const sec = (now - p.born) / 1000
        const px = this.sx(p.x + p.vx * sec, cam), py = this.sy(p.y + p.vy * sec, cam)
        ctx.beginPath()
        ctx.arc(px, py, (0.1 + age * 0.38) * scale, 0, 2 * PI)
        ctx.fillStyle = p.dark ? `rgba(20,20,24,${0.55 * (1 - age)})` : `rgba(110,115,122,${0.45 * (1 - age)})`
        ctx.fill()
      } else if (p.t === "plank") {
        // Wrackteil: gleitet mit Reibung aus, dreht sich, taucht zum Ende hin ab
        const sec = (now - p.born) / 1000
        const slide = (1 - Math.exp(-1.6 * sec)) / 1.6
        const px = this.sx(p.x + p.vx * slide, cam), py = this.sy(p.y + p.vy * slide, cam)
        ctx.save()
        ctx.translate(px, py)
        ctx.rotate(p.rot + p.vr * sec)
        ctx.globalAlpha = Math.min(1, (1 - age) * 3)
        ctx.fillStyle = p.light ? "#a9743a" : "#7a4a22"
        ctx.fillRect((-p.len * scale) / 2, (-0.045 * scale), p.len * scale, 0.09 * scale)
        ctx.restore()
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
      const sails = { reefed: "Segel gerafft", full: "Volle Segel", studding: "Beisegel" }
      ctx.font = `700 ${11 * u}px sans-serif`
      ctx.fillStyle = me.sa === "full" ? "#94a3b8" : "#fde68a"
      ctx.fillText("⛵ " + (sails[me.sa] || ""), cx, cy + 46 * u)
      const terr = NATIONS[state.me && state.me.tn]
      if (terr) {
        ctx.fillStyle = terr.color
        ctx.fillText("Gewässer: " + terr.name, cx, cy + 60 * u)
      }
    }

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
    const bx = W / 2 - 150 * u, by = H - 94 * u
    ctx.fillStyle = "rgba(8,20,34,0.72)"
    ctx.fillRect(bx - 8 * u, by - 12 * u, 316 * u, 92 * u)

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

    // Munition: 1 Vollkugeln, 2 Kettenkugel, 3 Brandgeschoss (gewählte hervorgehoben)
    const ammo = [["ball", "1 Kugel", "∞"], ["chain", "2 Kette", mine.am.c], ["fire", "3 Brand", mine.am.f]]
    ctx.font = `700 ${11 * u}px sans-serif`
    ammo.forEach(([k, label, n], i) => {
      const ax = bx + (76 + i * 78) * u
      ctx.fillStyle = mine.as === k ? "#fde68a" : "#64748b"
      ctx.fillText(`${label} ${n}`, ax, by + 50 * u)
    })

    if (mine.np && !mine.dk && me.a) {
      ctx.textAlign = "center"
      ctx.fillStyle = "rgba(8,20,34,0.78)"
      ctx.fillRect(W / 2 - 140 * u, by - 46 * u, 280 * u, 28 * u)
      ctx.fillStyle = me.v < 0.7 ? "#86efac" : "#fde68a"
      ctx.font = `700 ${13 * u}px sans-serif`
      ctx.fillText(me.v < 0.7 ? `F – in ${mine.np} andocken` : `${mine.np}: langsamer fahren zum Andocken`, W / 2, by - 31 * u)
    }
    ctx.textAlign = "left"
    ctx.textAlign = "right"
    ctx.fillStyle = "#cbd5e1"
    ctx.font = `700 ${12 * u}px sans-serif`
    ctx.fillText(`Abschüsse ${mine.k} · Tode ${mine.d}`, bx + 300 * u, by + 66 * u)

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
