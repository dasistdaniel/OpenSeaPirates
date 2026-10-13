// Tastatur: W/A/D bzw. Pfeile als Zustand (u = Segel, l/r = Ruder). Gesendet wird nur bei Änderung.

export class Input {
  constructor(onChange) {
    this.keys = { u: false, l: false, r: false }
    this.onChange = onChange
    this.enabled = false

    window.addEventListener("keydown", (e) => this.key(e, true))
    window.addEventListener("keyup", (e) => this.key(e, false))
    window.addEventListener("blur", () => this.releaseAll())
  }

  key(e, down) {
    if (!this.enabled) return
    if (e.ctrlKey || e.metaKey || e.altKey) return
    if (e.target.closest && e.target.closest("input, textarea, select")) return
    const map = { KeyW: "u", ArrowUp: "u", KeyA: "l", ArrowLeft: "l", KeyD: "r", ArrowRight: "r" }
    const k = map[e.code]
    if (!k) return
    e.preventDefault()
    if (this.keys[k] !== down) {
      this.keys[k] = down
      this.onChange(this.keys)
    }
  }

  releaseAll() {
    this.keys = { u: false, l: false, r: false }
    this.onChange(this.keys)
  }
}
