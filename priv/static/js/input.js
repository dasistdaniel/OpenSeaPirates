// Tastatur: W/A/D bzw. Pfeile als Zustand (u = Segel, l/r = Ruder, nur bei Änderung gesendet),
// Q/E = Breitseite links/rechts, Leertaste = beide Seiten (gehalten feuert jeweils erneut),
// S = Segelstufe weiterschalten (volle Segel → Beisegel → gerafft → volle Segel), M = Ton.

export class Input {
  constructor({ onKeys, onFire, onMute, onDock, onEscape, onAmmo, onHelp, onSail }) {
    this.keys = { u: false, l: false, r: false }
    this.firing = { left: false, right: false }
    this.h = { onKeys, onFire, onMute, onDock, onEscape, onAmmo, onHelp, onSail }
    this.enabled = false

    window.addEventListener("keydown", (e) => this.key(e, true))
    window.addEventListener("keyup", (e) => this.key(e, false))
    window.addEventListener("blur", () => this.releaseAll())

    // Gehaltene Breitseitentaste feuert erneut, sobald nachgeladen ist (der Server prüft)
    setInterval(() => {
      if (!this.enabled) return
      if (this.firing.left) this.h.onFire("left")
      if (this.firing.right) this.h.onFire("right")
    }, 150)
  }

  key(e, down) {
    if (!this.enabled) return
    if (e.code === "Escape" && down && !e.repeat) return void this.h.onEscape() // auch aus Eingabefeldern
    if (e.ctrlKey || e.metaKey || e.altKey) return
    if (e.target.closest && e.target.closest("input, textarea, select")) return

    const move = { KeyW: "u", ArrowUp: "u", KeyA: "l", ArrowLeft: "l", KeyD: "r", ArrowRight: "r" }
    const k = move[e.code]
    if (k) {
      e.preventDefault()
      if (this.keys[k] !== down) {
        this.keys[k] = down
        this.h.onKeys(this.keys)
      }
      return
    }

    if (e.code === "KeyQ" || e.code === "KeyE") {
      e.preventDefault()
      const side = e.code === "KeyQ" ? "left" : "right"
      this.firing[side] = down
      if (down && !e.repeat) this.h.onFire(side)
      return
    }

    if (e.code === "Space") {
      e.preventDefault() // sonst scrollt die Seite
      this.firing.left = down
      this.firing.right = down
      if (down && !e.repeat) {
        this.h.onFire("left")
        this.h.onFire("right")
      }
      return
    }

    if (down && !e.repeat) {
      if (e.code === "KeyF") return void this.h.onDock()
      if (e.code === "KeyH") return void this.h.onHelp()
      if (e.code === "KeyS") return void this.h.onSail()
      const ammo = { Digit1: "ball", Digit2: "chain", Digit3: "fire" }[e.code]
      if (ammo) return void this.h.onAmmo(ammo)
      if (e.code === "KeyM") this.h.onMute()
    }
  }

  releaseAll() {
    this.keys = { u: false, l: false, r: false }
    this.firing = { left: false, right: false }
    this.h.onKeys(this.keys)
  }
}
