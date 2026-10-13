// Kleine WebAudio-Synthese für Kampfgeräusche (keine Dateien nötig). M schaltet stumm.

const KEY = "osp-muted"

export class Sound {
  constructor() {
    this.ctx = null
    try { this.muted = localStorage.getItem(KEY) === "1" } catch (_) { this.muted = false }
  }

  toggle() {
    this.muted = !this.muted
    try { localStorage.setItem(KEY, this.muted ? "1" : "0") } catch (_) {}
    return this.muted
  }

  tone(f0, f1, dur, type, gain, vol) {
    const a = this.ctx
    const t0 = a.currentTime
    const o = a.createOscillator()
    o.type = type
    o.frequency.setValueAtTime(f0, t0)
    o.frequency.exponentialRampToValueAtTime(f1, t0 + dur)
    const g = a.createGain()
    g.gain.setValueAtTime(gain * vol, t0)
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur)
    o.connect(g).connect(a.destination)
    o.start(t0)
    o.stop(t0 + dur)
  }

  // name: boom | hit | kill | coin; vol 0..1 (Entfernung/Beteiligung)
  play(name, vol = 1) {
    if (this.muted) return
    try {
      if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)()
      if (this.ctx.state === "suspended") this.ctx.resume()
      if (name === "boom") this.tone(140, 40, 0.25, "sawtooth", 0.1, vol)
      else if (name === "hit") this.tone(300, 70, 0.18, "square", 0.08, vol)
      else if (name === "kill") this.tone(110, 30, 0.5, "sawtooth", 0.16, vol)
      else if (name === "coin") { this.tone(900, 1300, 0.08, "square", 0.06, vol); this.tone(1300, 1700, 0.1, "square", 0.05, vol) }
    } catch (_) {}
  }
}
