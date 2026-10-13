// Gelände-Chunks: vom Server anfordern, als Textur zeichnen, Höhen abfragen (Minikarte)

const TEX_PX_PER_WE = 12

export class Chunks {
  constructor(net) {
    this.net = net
    this.size = 16
    this.res = 2
    this.land = 0.66
    this.map = new Map() // "cx,cy" -> { bytes, canvas|null }
    this.pending = new Set()
    this.builtThisFrame = 0
  }

  configure({ chunk, res, land }) {
    this.size = chunk
    this.res = res
    this.land = land
    this.edge = chunk * res + 1
    this.map.clear()
    this.pending.clear()
  }

  key(cx, cy) {
    return cx + "," + cy
  }

  set(cx, cy, bytes) {
    this.pending.delete(this.key(cx, cy))
    this.map.set(this.key(cx, cy), { bytes, canvas: null })
  }

  get(cx, cy) {
    return this.map.get(this.key(cx, cy))
  }

  // Alle Chunks im Umkreis `radius` (WE) um (x, y) bereithalten; nahe zuerst, wenige gleichzeitig
  ensureAround(x, y, radius, maxInFlight = 8) {
    const s = this.size
    const c0x = Math.floor((x - radius) / s), c1x = Math.floor((x + radius) / s)
    const c0y = Math.floor((y - radius) / s), c1y = Math.floor((y + radius) / s)
    const wanted = []
    for (let cx = c0x; cx <= c1x; cx++) {
      for (let cy = c0y; cy <= c1y; cy++) {
        const mx = (cx + 0.5) * s - x, my = (cy + 0.5) * s - y
        const d = Math.hypot(mx, my)
        if (d <= radius + s * 0.71) wanted.push({ cx, cy, d })
      }
    }
    wanted.sort((a, b) => a.d - b.d)
    for (const w of wanted) {
      if (this.pending.size >= maxInFlight) break
      const k = this.key(w.cx, w.cy)
      if (!this.map.has(k) && !this.pending.has(k)) {
        this.pending.add(k)
        this.net.send({ t: "chunk", cx: w.cx, cy: w.cy })
      }
    }
    this.prune(x, y, radius + s * 3)
  }

  // Weit entfernte Chunks vergessen
  prune(x, y, keepRadius) {
    if (this.map.size < 160) return
    for (const k of this.map.keys()) {
      const [cx, cy] = k.split(",").map(Number)
      const d = Math.hypot((cx + 0.5) * this.size - x, (cy + 0.5) * this.size - y)
      if (d > keepRadius) this.map.delete(k)
    }
  }

  // Höhe 0..1 an einem Weltpunkt (nächste Stützstelle) oder null, wenn der Chunk fehlt
  heightAt(x, y) {
    const cx = Math.floor(x / this.size), cy = Math.floor(y / this.size)
    const c = this.map.get(this.key(cx, cy))
    if (!c) return null
    const i = Math.min(Math.round((x - cx * this.size) * this.res), this.edge - 1)
    const j = Math.min(Math.round((y - cy * this.size) * this.res), this.edge - 1)
    return c.bytes[j * this.edge + i] / 255
  }

  // Textur eines Chunks (lazy, höchstens ein paar pro Frame, damit es nicht ruckelt)
  texture(entry) {
    if (entry.canvas) return entry.canvas
    if (this.builtThisFrame >= 3) return null
    this.builtThisFrame++
    entry.canvas = this.buildTexture(entry.bytes)
    return entry.canvas
  }

  buildTexture(bytes) {
    const px = this.size * TEX_PX_PER_WE
    const canvas = document.createElement("canvas")
    canvas.width = canvas.height = px
    const ctx = canvas.getContext("2d")
    const img = ctx.createImageData(px, px)
    const d = img.data
    const e = this.edge
    const land = this.land

    for (let y = 0; y < px; y++) {
      const fy = (y / TEX_PX_PER_WE) * this.res
      const j = Math.min(Math.floor(fy), e - 2)
      const ty = fy - j
      for (let x = 0; x < px; x++) {
        const fx = (x / TEX_PX_PER_WE) * this.res
        const i = Math.min(Math.floor(fx), e - 2)
        const tx = fx - i
        const a = bytes[j * e + i], b = bytes[j * e + i + 1]
        const c = bytes[(j + 1) * e + i], dd = bytes[(j + 1) * e + i + 1]
        const h = (a + (b - a) * tx + (c + (dd - c) * tx - (a + (b - a) * tx)) * ty) / 255
        // leichtes Pixelrauschen gegen Banding
        const n = (((x * 73856093) ^ (y * 19349663)) & 15) - 7
        const o = (y * px + x) * 4
        shade(h, land, n, d, o)
      }
    }
    ctx.putImageData(img, 0, 0)
    return canvas
  }
}

// Farbe zu einer Höhe: tiefes Wasser → flach → Schaumkante → Sand → Gras → Wald → Fels
function shade(h, land, n, d, o) {
  let r, g, b
  if (h < land) {
    if (h < 0.5) {
      r = 9; g = 56; b = 92
    } else if (h < 0.6) {
      const t = (h - 0.5) / 0.1
      r = 9 + t * 8; g = 56 + t * 38; b = 92 + t * 40
    } else {
      const t = (h - 0.6) / (land - 0.6)
      r = 17 + t * 60; g = 94 + t * 78; b = 132 + t * 48
    }
    const foam = land - h
    if (foam < 0.014) {
      const f = 1 - foam / 0.014
      r += (235 - r) * f * 0.85; g += (248 - g) * f * 0.85; b += (248 - b) * f * 0.85
    }
  } else {
    const t = h - land
    if (t < 0.035) { r = 232; g = 212; b = 152 }
    else if (t < 0.11) {
      const k = (t - 0.035) / 0.075
      r = 232 - k * 110; g = 212 - k * 52; b = 152 - k * 72
    } else if (t < 0.2) { r = 70; g = 126; b = 66 }
    else { r = 128; g = 124; b = 108 }
  }
  d[o] = clamp(r + n); d[o + 1] = clamp(g + n); d[o + 2] = clamp(b + n); d[o + 3] = 255
}

function clamp(v) {
  return v < 0 ? 0 : v > 255 ? 255 : v
}
