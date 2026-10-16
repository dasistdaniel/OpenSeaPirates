// WebAudio-Synthese ohne Dateien: Kampfgeräusche plus Meeresatmosphäre (Brandung, Wind, Bugwasser,
// Möwen, knarrendes Holz). M schaltet stumm.

const KEY = "osp-muted"

export class Sound {
  constructor() {
    this.ctx = null
    this.amb = null // Atmosphäre-Knoten, entsteht mit dem AudioContext
    try { this.muted = localStorage.getItem(KEY) === "1" } catch (_) { this.muted = false }
    this.volume = 0.8
    try {
      const v = parseFloat(localStorage.getItem("osp-volume"))
      if (v >= 0 && v <= 1) this.volume = v
    } catch (_) {}
  }

  setVolume(v) {
    this.volume = Math.min(Math.max(v, 0), 1)
    try { localStorage.setItem("osp-volume", String(this.volume)) } catch (_) {}
    this.applyMaster()
  }

  toggle() {
    this.muted = !this.muted
    try { localStorage.setItem(KEY, this.muted ? "1" : "0") } catch (_) {}
    this.applyMaster()
    return this.muted
  }

  applyMaster() {
    if (!this.amb) return
    this.amb.master.gain.setTargetAtTime(this.muted ? 0 : this.volume, this.ctx.currentTime, 0.05)
  }

  // Muss nach einer Nutzeraktion laufen (Beitreten), sonst blockt der Browser den Ton.
  start() {
    try {
      if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)()
      if (this.ctx.state === "suspended") this.ctx.resume()
      if (!this.amb) this.buildAmbience()
    } catch (_) {}
  }

  noiseBuffer(brown) {
    const a = this.ctx
    const buf = a.createBuffer(1, a.sampleRate * 3, a.sampleRate)
    const d = buf.getChannelData(0)
    let last = 0
    for (let i = 0; i < d.length; i++) {
      const w = Math.random() * 2 - 1
      if (brown) { last = (last + 0.02 * w) / 1.02; d[i] = last * 3.5 } else d[i] = w
    }
    return buf
  }

  loop(buffer) {
    const s = this.ctx.createBufferSource()
    s.buffer = buffer
    s.loop = true
    s.start()
    return s
  }

  buildAmbience() {
    const a = this.ctx
    const master = a.createGain()
    master.gain.value = this.muted ? 0 : this.volume
    master.connect(a.destination)

    const white = this.noiseBuffer(false), brown = this.noiseBuffer(true)

    // Brandung: tiefes Rauschen, dessen Lautstärke langsam wie Dünung an- und abschwillt
    const surf = a.createGain()
    surf.gain.value = 0.16
    const surfLp = a.createBiquadFilter()
    surfLp.type = "lowpass"
    surfLp.frequency.value = 520
    this.loop(brown).connect(surfLp).connect(surf).connect(master)
    const swell = a.createOscillator()
    swell.frequency.value = 0.11
    const swellDepth = a.createGain()
    swellDepth.gain.value = 0.09
    swell.connect(swellDepth).connect(surf.gain)
    swell.start()

    // Wind: Bandrauschen, Stärke folgt Rückenwind/Gegenwind (siehe ambient())
    const wind = a.createGain()
    wind.gain.value = 0.02
    const windBp = a.createBiquadFilter()
    windBp.type = "bandpass"
    windBp.frequency.value = 650
    windBp.Q.value = 0.7
    this.loop(white).connect(windBp).connect(wind).connect(master)
    const gust = a.createOscillator()
    gust.frequency.value = 0.07
    const gustDepth = a.createGain()
    gustDepth.gain.value = 120
    gust.connect(gustDepth).connect(windBp.frequency)
    gust.start()

    // Bugwasser: Rauschen, das mit dem Tempo lauter wird
    const hull = a.createGain()
    hull.gain.value = 0
    const hullLp = a.createBiquadFilter()
    hullLp.type = "lowpass"
    hullLp.frequency.value = 1100
    this.loop(white).connect(hullLp).connect(hull).connect(master)

    this.amb = { master, wind, hull, hullLp, white, nextGull: 0, nextCreak: 0 }
  }

  // Jeden Frame aufrufen: speed in WE/s, windBonus -0.4..0.4 für den eigenen Kurs, turning = lenkt gerade
  ambient(speed, windBonus, turning, now) {
    if (!this.amb || this.muted) return
    const t = this.ctx.currentTime
    const sp = Math.min(speed / 2.5, 1)
    this.amb.hull.gain.setTargetAtTime(sp * 0.07, t, 0.4)
    this.amb.hullLp.frequency.setTargetAtTime(700 + sp * 1400, t, 0.4)
    this.amb.wind.gain.setTargetAtTime(0.02 + 0.045 * (0.5 + windBonus / 0.8), t, 0.8)

    if (now > this.amb.nextGull) {
      if (this.amb.nextGull) this.gull()
      this.amb.nextGull = now + 9000 + Math.random() * 16000
    }
    if (now > this.amb.nextCreak) {
      if (this.amb.nextCreak && (turning || speed > 0.8)) this.creak(turning ? 1 : 0.6)
      this.amb.nextCreak = now + 4000 + Math.random() * 8000
    }
  }

  gull() {
    const a = this.ctx, t0 = a.currentTime
    const n = 2 + Math.floor(Math.random() * 2)
    const pan = a.createStereoPanner ? a.createStereoPanner() : null
    if (pan) pan.pan.value = Math.random() * 2 - 1
    for (let i = 0; i < n; i++) {
      const t = t0 + i * 0.28
      const o = a.createOscillator()
      o.type = "triangle"
      const base = 1500 + Math.random() * 400
      o.frequency.setValueAtTime(base, t)
      o.frequency.exponentialRampToValueAtTime(base * 1.5, t + 0.07)
      o.frequency.exponentialRampToValueAtTime(base * 0.75, t + 0.24)
      const g = a.createGain()
      g.gain.setValueAtTime(0.0001, t)
      g.gain.exponentialRampToValueAtTime(0.05, t + 0.04)
      g.gain.exponentialRampToValueAtTime(0.0001, t + 0.26)
      const bp = a.createBiquadFilter()
      bp.type = "bandpass"
      bp.frequency.value = 2000
      bp.Q.value = 1.2
      o.connect(bp).connect(g)
      if (pan) g.connect(pan).connect(this.amb.master)
      else g.connect(this.amb.master)
      o.start(t)
      o.stop(t + 0.3)
    }
  }

  // Knarrendes Holz: tiefe Säge mit schnellem Vibrato
  creak(strength) {
    const a = this.ctx, t0 = a.currentTime
    const o = a.createOscillator()
    o.type = "sawtooth"
    const f = 70 + Math.random() * 60
    o.frequency.setValueAtTime(f, t0)
    o.frequency.linearRampToValueAtTime(f * (0.85 + Math.random() * 0.4), t0 + 0.5)
    const lfo = a.createOscillator()
    lfo.frequency.value = 18 + Math.random() * 14
    const lfoG = a.createGain()
    lfoG.gain.value = 6
    lfo.connect(lfoG).connect(o.frequency)
    const lp = a.createBiquadFilter()
    lp.type = "lowpass"
    lp.frequency.value = 380
    const g = a.createGain()
    g.gain.setValueAtTime(0.0001, t0)
    g.gain.exponentialRampToValueAtTime(0.035 * strength, t0 + 0.12)
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.55)
    o.connect(lp).connect(g).connect(this.amb.master)
    o.start(t0); lfo.start(t0)
    o.stop(t0 + 0.6); lfo.stop(t0 + 0.6)
  }

  // --- Effekte -----------------------------------------------------------------------------

  tone(f0, f1, dur, type, gain, vol) {
    const a = this.ctx
    const t0 = a.currentTime
    const o = a.createOscillator()
    o.type = type
    o.frequency.setValueAtTime(f0, t0)
    o.frequency.exponentialRampToValueAtTime(f1, t0 + dur)
    const g = a.createGain()
    g.gain.setValueAtTime(gain * vol * this.volume, t0)
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur)
    o.connect(g).connect(a.destination)
    o.start(t0)
    o.stop(t0 + dur)
  }

  // Rauschstoß durch einen Filter, der von f0 nach f1 fährt
  burst(f0, f1, dur, type, gain, vol, q = 1) {
    const a = this.ctx
    const t0 = a.currentTime
    const src = a.createBufferSource()
    src.buffer = this.amb ? this.amb.white : this.noiseBuffer(false)
    const f = a.createBiquadFilter()
    f.type = type
    f.Q.value = q
    f.frequency.setValueAtTime(f0, t0)
    f.frequency.exponentialRampToValueAtTime(f1, t0 + dur)
    const g = a.createGain()
    g.gain.setValueAtTime(gain * vol * this.volume, t0)
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur)
    src.connect(f).connect(g).connect(a.destination)
    src.start(t0)
    src.stop(t0 + dur + 0.05)
  }

  // name: boom | hit | kill | coin | splash | bell | sail; vol 0..1 (Entfernung/Beteiligung)
  play(name, vol = 1) {
    if (this.muted) return
    try {
      this.start()
      if (name === "boom") {
        this.burst(1800, 160, 0.35, "lowpass", 0.5, vol)
        this.tone(110, 32, 0.4, "sine", 0.28, vol)
      } else if (name === "hit") {
        this.burst(2600, 500, 0.16, "bandpass", 0.35, vol, 0.8) // Holz splittert
        this.tone(220, 55, 0.2, "square", 0.05, vol)
      } else if (name === "kill") {
        this.burst(900, 70, 0.9, "lowpass", 0.6, vol)
        this.tone(90, 25, 0.9, "sawtooth", 0.14, vol)
        this.tone(300, 50, 0.5, "square", 0.04, vol)
      } else if (name === "coin") {
        this.tone(1250, 1250, 0.07, "square", 0.05, vol)
        setTimeout(() => this.ctx && this.tone(1880, 1880, 0.16, "square", 0.05, vol), 70)
      } else if (name === "splash") {
        this.burst(2400, 800, 0.22, "bandpass", 0.2, vol, 0.5)
      } else if (name === "bell") {
        for (const [f, g] of [[880, 0.08], [1318, 0.05], [1760, 0.03]]) this.tone(f, f * 0.995, 1.4, "sine", g, vol)
      } else if (name === "sail") {
        this.burst(500, 1400, 0.3, "bandpass", 0.18, vol, 0.6) // Segeltuch schlägt
      }
    } catch (_) {}
  }
}
