// WebSocket-Verbindung zum Server (Protokoll: siehe lib/osp/web/socket.ex)

const TOKEN_KEY = "osp-token"

// Anonymes, langlebiges Token als Identität (später: Konten)
export function playerToken() {
  try {
    let t = localStorage.getItem(TOKEN_KEY)
    if (!t || t.length < 16) {
      const bytes = crypto.getRandomValues(new Uint8Array(18))
      t = Array.from(bytes, (b) => b.toString(36).padStart(2, "0")).join("").slice(0, 28)
      localStorage.setItem(TOKEN_KEY, t)
    }
    return t
  } catch (_) {
    return "tmp" + Math.random().toString(36).slice(2, 14)
  }
}

export class Net {
  constructor(handlers) {
    this.h = handlers
    this.ws = null
    this.name = ""
    this.wanted = false
    this.retry = 0
    this.token = playerToken()
  }

  connect(name) {
    this.name = name
    this.wanted = true
    this.open()
  }

  open() {
    const proto = location.protocol === "https:" ? "wss" : "ws"
    const ws = new WebSocket(`${proto}://${location.host}/ws`)
    ws.binaryType = "arraybuffer"
    this.ws = ws

    ws.onopen = () => {
      this.retry = 0
      this.h.onStatus?.(null)
      this.send({ t: "join", token: this.token, name: this.name })
    }

    ws.onmessage = (ev) => {
      if (typeof ev.data === "string") {
        const msg = JSON.parse(ev.data)
        if (msg.t === "welcome") this.h.onWelcome?.(msg)
        else if (msg.t === "snap") this.h.onSnap?.(msg)
      } else {
        const view = new DataView(ev.data)
        if (view.getUint8(0) === 1) {
          const cx = view.getInt32(1)
          const cy = view.getInt32(5)
          this.h.onChunk?.(cx, cy, new Uint8Array(ev.data, 9))
        }
      }
    }

    ws.onclose = () => {
      this.h.onStatus?.("Verbindung verloren – verbinde neu …")
      if (!this.wanted) return
      const delay = Math.min(1000 * 2 ** this.retry, 5000)
      this.retry++
      setTimeout(() => this.wanted && this.open(), delay)
    }
  }

  get ready() {
    return this.ws && this.ws.readyState === WebSocket.OPEN
  }

  send(obj) {
    if (this.ready) this.ws.send(JSON.stringify(obj))
  }
}
