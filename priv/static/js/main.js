// Einstieg: verbindet Netz, Gelände, Eingabe, Darstellung und Ton

import { Net } from "./net.js"
import { Chunks } from "./chunks.js"
import { Input } from "./input.js"
import { Renderer } from "./render.js"
import { Snapshots } from "./snapshots.js"
import { Minimap } from "./minimap.js"
import { Sound } from "./audio.js"
import { SPRITE_COLORS } from "./minimap.js"
import { Waypoints } from "./waypoints.js"
import { Shop } from "./shop.js"

const NAME_KEY = "osp-name"
const $ = (id) => document.getElementById(id)

const statusEl = $("status")
const hudEl = $("hud")
const posEl = $("hud-pos")

const snaps = new Snapshots()
const sound = new Sound()
const players = { list: [] } // alle Spieler [Kennung, Name, Farbe, x, y, Abschüsse, Gold], alle 0,5 s neu
const names = new Map() // id -> Name (für Meldungen, auch von Schiffen außer Sicht)
let joined = false
let worldSeed = null
let sailSent = null
let myId = null
let docked = false

const net = new Net({
  onWelcome(msg) {
    // Gelände nur neu laden, wenn die Welt eine andere ist (Server-Neustart mit neuem Seed)
    if (msg.seed !== worldSeed) chunks.configure(msg)
    worldSeed = msg.seed
    snaps.list.length = 0 // keine Interpolation über die Lücke der Unterbrechung
    docked = shop.update({ t: "shop", open: false }) // Hafen-Ansicht kommt vom Server, falls angedockt
    input.releaseAll()
    myId = msg.you
    joined = true
    input.enabled = true
    $("join").hidden = true
    hudEl.hidden = false
  },
  onSnap(msg) {
    snaps.push(msg)
    for (const s of msg.ships) names.set(s.i, s.n)
    if (msg.pl) players.list = msg.pl
    for (const ev of msg.ev || []) handleEvent(ev)
  },
  onShop(msg) {
    const was = docked
    docked = shop.update(msg)
    if (docked) input.releaseAll()
    if (docked !== was) sound.play("bell", 0.7)
  },
  onError(msg) {
    const texts = { full: "Die Welt ist voll. Versuch es später noch einmal." }
    net.wanted = false
    net.ws && net.ws.close()
    statusEl.hidden = false
    statusEl.textContent = texts[msg.reason] || "Beitritt nicht möglich."
    $("join-button").disabled = false
  },
  onChunk(cx, cy, bytes) {
    chunks.set(cx, cy, bytes)
  },
  onStatus(text) {
    statusEl.hidden = !text
    statusEl.textContent = text || ""
    if (text) input.releaseAll()
  },
})

const chunks = new Chunks(net)
const input = new Input({
  onKeys: (k) => net.send({ t: "input", u: k.u, l: k.l, r: k.r }),
  onFire: (side) => net.send({ t: "fire", side }),
  onMute: () => sound.toggle(),
  onAmmo: (kind) => net.send({ t: "ammo", kind }),
  onHelp: () => toggleHelp(),
  // S schaltet die Segelstufe weiter: voll → Beisegel → gerafft → voll. Schnelles Mehrfachdrücken
  // zählt weiter, auch wenn der Server die neue Stufe noch nicht gemeldet hat.
  onSail: () => {
    const order = ["full", "studding", "reefed"]
    const shown = snaps.latest && snaps.latest.me && snaps.latest.me.sa
    const cur = sailSent && performance.now() - sailSent.at < 400 ? sailSent.mode : shown
    const next = order[(order.indexOf(cur) + 1) % order.length]
    sailSent = { mode: next, at: performance.now() }
    net.send({ t: "sail", mode: next })
    sound.play("sail", 0.8)
  },
  // F: andocken oder ablegen; Esc (nur ablegen)
  onDock: (onlyUndock) => {
    if (docked) net.send({ t: "undock" })
    else if (!onlyUndock) net.send({ t: "dock" })
  },
})
const renderer = new Renderer($("game"), chunks)
const minimap = new Minimap($("minimap"), chunks)
const waypoints = new Waypoints()
renderer.waypoints = waypoints

// Mausrad zoomt; Linksklick setzt einen Wegpunkt (Klick auf einen vorhandenen entfernt ihn),
// Rechtsklick entfernt den nächsten
const gameCanvas = $("game")
gameCanvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault()
    const dy = e.deltaMode === 1 ? e.deltaY * 33 : e.deltaY
    renderer.zoomBy(Math.pow(1.0015, dy))
  },
  { passive: false },
)
gameCanvas.addEventListener("click", (e) => {
  if (!joined || docked) return
  const p = renderer.worldAt(e.clientX, e.clientY)
  if (!p) return
  if (!waypoints.removeNear(p.x, p.y, renderer.view.cur * 0.035)) waypoints.add(p.x, p.y)
})
gameCanvas.addEventListener("contextmenu", (e) => {
  e.preventDefault()
  const p = renderer.worldAt(e.clientX, e.clientY)
  if (joined && p) waypoints.removeNear(p.x, p.y)
})
const shop = new Shop($("shop"), net)

// Holzsplitter und Wrackteile: fliegen auseinander, treiben aus und versinken
function splinters(x, y, n, life = 1100) {
  for (let i = 0; i < n; i++) {
    const a = Math.random() * 2 * Math.PI, v = 0.8 + Math.random() * 1.8
    renderer.effect({
      t: "plank", x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v,
      rot: Math.random() * 6.3, vr: (Math.random() - 0.5) * 6, len: 0.16 + Math.random() * 0.22,
      light: Math.random() < 0.4, life: life * (0.7 + Math.random() * 0.5),
    })
  }
}

// --- Ereignisse vom Server: Effekte und Ton -----------------------------------------------
function handleEvent(ev) {
  const kind = ev[0]
  const nm = (id) => names.get(id) || "Unbekannt"

  if (kind === "fire") {
    const [, id, , x, y] = ev
    renderer.effect({ t: "ring", x, y, life: 300 })
    sound.play("boom", id === myId ? 1 : 0.4)
  } else if (kind === "hit") {
    const [, victim, by, amount, x, y] = ev
    renderer.effect({ t: "expl", x, y, life: 420, size: amount >= 3 ? 1.1 : 0.55 })
    splinters(x, y, 3)
    renderer.effect({
      t: "text", x, y, life: 800, text: "-" + amount, color: victim === myId ? "#fca5a5" : "#fde68a",
    })
    sound.play("hit", victim === myId || by === myId ? 1 : 0.35)
  } else if (kind === "kill") {
    const [, killer, victim, x, y] = ev
    renderer.effect({ t: "expl", x, y, life: 800, size: 2.0 })
    splinters(x, y, 12, 5200)
    renderer.killFeed(`${killer ? nm(killer) : "Riff"} ⚓ ${nm(victim)}`, killer === myId || victim === myId)
    sound.play("kill", 1)
  } else if (kind === "rake") {
    renderer.effect({ t: "text", x: ev[1], y: ev[2] - 0.4, life: 1000, text: "Längsfeuer!", color: "#fb923c" })
  } else if (kind === "splash") {
    renderer.effect({ t: "ring", x: ev[1], y: ev[2], life: 400 })
    sound.play("splash", 0.5)
  } else if (kind === "loot") {
    const [, id, gold, x, y] = ev
    renderer.effect({ t: "text", x, y, life: 1100, text: "+" + gold + " Gold", color: "#fbbf24" })
    if (id === myId) sound.play("coin", 1)
  } else if (kind === "respawn") {
    renderer.effect({ t: "ring", x: ev[2], y: ev[3], life: 700 })
  }
}

// --- Hilfe, Lautstärke -------------------------------------------------------------------
const helpEl = $("help")
function toggleHelp(force) {
  const show = force === undefined ? helpEl.hidden : force
  helpEl.hidden = !show
}
$("help-btn").addEventListener("click", () => toggleHelp())
$("help-close").addEventListener("click", () => toggleHelp(false))
helpEl.addEventListener("click", (e) => { if (e.target === helpEl) toggleHelp(false) })
window.addEventListener("keydown", (e) => { if (e.code === "Escape" && !helpEl.hidden) toggleHelp(false) })

const vol = $("volume")
vol.value = String(Math.round(sound.volume * 100))
vol.addEventListener("input", () => sound.setVolume(Number(vol.value) / 100))

// --- Beitreten ----------------------------------------------------------------------
const nameInput = $("name")
try { nameInput.value = localStorage.getItem(NAME_KEY) || "" } catch (_) {}
nameInput.focus()

$("join-form").addEventListener("submit", (e) => {
  e.preventDefault()
  const name = nameInput.value.trim()
  try { localStorage.setItem(NAME_KEY, name) } catch (_) {}
  sound.start() // Klick auf Beitreten schaltet den Ton frei
  net.connect(name)
  $("join-button").disabled = true
})

// --- Schleife -----------------------------------------------------------------------
const LOAD_RADIUS_WE = 48 // Chunks in diesem Umkreis laden (Bildschirm ± Minikarte)

let lastHeading = 0
let lastBoard = 0

// Rangliste der Online-Spieler: Abschüsse, Gold, Richtung und Entfernung (Namen nur als Text einsetzen)
const boardEl = $("board")
function renderBoard(me, state) {
  const list = [...players.list].sort((a, b) => b[5] - a[5] || b[6] - a[6]).slice(0, 8)
  const live = new Map(state.ships.map((s) => [s.i, s]))
  boardEl.hidden = list.length === 0
  const rows = [Object.assign(document.createElement("h4"), { textContent: "Online" })]
  for (const [id, name, color, px, py, kills, gold] of list) {
    const row = document.createElement("div")
    row.className = "row" + (id === state.you ? " me" : "")
    const dot = document.createElement("span")
    dot.className = "dot"
    dot.style.background = SPRITE_COLORS[color % SPRITE_COLORS.length]
    const nm = Object.assign(document.createElement("span"), { className: "name", textContent: name })
    const k = Object.assign(document.createElement("span"), { className: "num", textContent: `⚔${kills}` })
    const g = Object.assign(document.createElement("span"), { className: "num", textContent: `${gold}g` })
    const arrow = Object.assign(document.createElement("span"), { className: "arrow" })
    const dist = Object.assign(document.createElement("span"), { className: "num" })
    if (id !== state.you) {
      const s = live.get(id)
      const x = s ? s.x : px, y = s ? s.y : py
      arrow.textContent = "➤"
      arrow.style.transform = `rotate(${Math.atan2(y - me.y, x - me.x)}rad)`
      dist.textContent = String(Math.round(Math.hypot(x - me.x, y - me.y)))
    }
    row.append(dot, nm, k, g, arrow, dist)
    rows.push(row)
  }
  boardEl.replaceChildren(...rows)
}

function frame(now) {
  requestAnimationFrame(frame)
  const state = snaps.sample(now)
  renderer.draw(state, now)

  if (state && joined) {
    const me = state.ships.find((s) => s.i === state.you)
    if (me) {
      shop.setColor(me.c)
      chunks.ensureAround(me.x, me.y, LOAD_RADIUS_WE)
      if (waypoints.reach(me)) sound.play("coin", 0.5)
      minimap.draw(me, state.ships, now, players.list, waypoints.list)
      renderer.players = players.list
      if (now - lastBoard > 250) {
        lastBoard = now
        renderBoard(me, state)
      }
      const dh = Math.abs(Math.atan2(Math.sin(me.h - lastHeading), Math.cos(me.h - lastHeading)))
      lastHeading = me.h
      sound.ambient(me.v, Math.cos(me.h - state.w) * 0.4, dh > 0.01 && me.v > 0.3, now)
      posEl.textContent =
        `x ${me.x.toFixed(0)}  y ${me.y.toFixed(0)}  ·  Tempo ${me.v.toFixed(1)}  ·  ` +
        `${state.ships.length - 1} Schiffe in der Nähe`
    }
  }
}

requestAnimationFrame(frame)

// Für Entwicklung und Browser-Tests: Zugriff auf die laufenden Teile
window.osp = { net, snaps, chunks, renderer, shop }
