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
import { NATIONS, standing } from "./nations.js"
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
    $("nation").hidden = true
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
    if (msg.reason === "nation_required") return showNationPicker(msg.nations)
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
  const nm = (id) => names.get(id) || (String(id).startsWith("fort:") ? "Fort" : "Unbekannt")

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
  } else if (kind === "rep") {
    const [, id, nation, delta, value, x, y] = ev
    const n = NATIONS[nation]
    if (id !== myId || !n) return
    renderer.effect({
      t: "text", x, y: y - 0.6, life: 1400,
      text: `Ruf ${n.name} ${delta > 0 ? "+" : "−"}${Math.abs(delta)}`,
      color: delta > 0 ? "#86efac" : "#fca5a5",
    })
    const was = standing(value - delta), now = standing(value)
    if (was !== now && now === "suspicious") flash(`Die Jäger von ${n.name} suchen dich`, "#fbbf24")
    else if (was !== now && now === "wanted") flash(`${n.name} sucht dich! Häfen verweigern den Handel, Forts schießen`, "#f87171")
  } else if (kind === "assault") {
    flash(`${portName(ev[1])} wird angegriffen`, "#fbbf24")
  } else if (kind === "captured") {
    const [, portId, owner, old] = ev
    const mine = (snaps.latest && snaps.latest.ships.find((s) => s.i === myId)?.na) === owner
    flash(`${portName(portId)} erobert von ${NATIONS[owner] ? NATIONS[owner].name : "?"}!`, mine ? "#86efac" : "#f87171", 6000)
    sound.play("kill", 0.6)
  } else if (kind === "reverted") {
    flash(`${portName(ev[1])} fällt an ${NATIONS[ev[2]] ? NATIONS[ev[2]].name : "?"} zurück`, "#fbbf24", 5000)
  } else if (kind === "assault_end") {
    flash(`Angriff auf ${portName(ev[1])} abgebrochen`, "#94a3b8")
  } else if (kind === "quest_done") {
    const [, id, gold, rep, nation] = ev
    const n = NATIONS[nation]
    if (id !== myId) return
    flash(`Auftrag erfüllt: +${gold} Gold, Ruf ${n ? n.name : ""} +${rep}`, "#86efac")
    sound.play("coin", 1)
  } else if (kind === "quest_lost") {
    if (ev[1] !== myId) return
    flash(ev[2] === "death" ? "Auftrag gescheitert: Ware verloren" : "Auftrag abgelaufen", "#fbbf24")
  } else if (kind === "fort_warn") {
    if (ev[2] === myId) flash("Das Fort eröffnet das Feuer!", "#f87171")
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

// --- Nationswahl und Gebietsmeldung ---------------------------------------------------------------------
// Der Server schickt die fünf Nationen; Namen und Texte nur per textContent einsetzen
function showNationPicker(nations) {
  const list = $("nation-list")
  const buttons = (nations || []).map((n) => {
    const b = document.createElement("button")
    b.type = "button"
    b.style.borderLeftColor = n.color
    const img = document.createElement("img")
    img.src = `/images/flags/${encodeURIComponent(n.id)}.png`
    img.alt = ""
    const name = Object.assign(document.createElement("b"), { textContent: n.name })
    const bonus = Object.assign(document.createElement("span"), { className: "bonus", textContent: n.bonus })
    b.append(img, name, bonus)
    b.addEventListener("click", () => {
      $("nation").hidden = true
      net.chooseNation(n.id)
    })
    return b
  })
  list.replaceChildren(...buttons)
  $("join").hidden = true // der Namensbildschirm liegt sonst über der Wahl
  $("nation").hidden = false
}

let lastTerritory = null
let territoryTimer = null

// Name eines Hafens aus dem letzten Schnappschuss (Ereignisse tragen nur die ID)
function portName(id) {
  const port = ((snaps.latest && snaps.latest.ports) || []).find((p) => p[0] === id)
  return port ? port[3] : "Ein Hafen"
}

// Kurze Meldung oben in der Mitte (Gebietswechsel, Ruf, Fort)
function flash(text, color, ms = 4000) {
  const el = $("territory")
  el.textContent = text
  el.style.color = color
  el.hidden = false
  clearTimeout(territoryTimer)
  territoryTimer = setTimeout(() => (el.hidden = true), ms)
}

function territoryChanged(tn) {
  if (tn === lastTerritory) return
  const first = lastTerritory === null
  lastTerritory = tn
  const nation = NATIONS[tn]
  if (first || !nation) return
  flash(`Du betrittst ${nation.adjective} Gewässer`, nation.color)
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

// Quest-Log links: Titel, Fortschritt, Restzeit und grobe Richtung (Pfeil, Himmelsrichtung, gerundete Entfernung)
const questEl = $("quest-log")
const COMPASS = ["O", "NO", "N", "NW", "W", "SW", "S", "SO"]

function compass(dx, dy) {
  const deg = (Math.atan2(-dy, dx) * 180) / Math.PI // Norden oben, y wächst nach unten
  return COMPASS[((Math.round(deg / 45) % 8) + 8) % 8]
}

function renderQuests(me, quests) {
  questEl.hidden = !quests || quests.length === 0
  if (questEl.hidden) return
  const rows = [Object.assign(document.createElement("h4"), { textContent: "Aufträge" })]
  for (const q of quests) {
    const row = document.createElement("div")
    row.className = "q"
    const nation = NATIONS[q.tn]
    const title =
      q.k === "delivery"
        ? `Lieferung nach ${q.to || "?"}`
        : `Jäger von ${nation ? nation.name : "?"}: ${q.have}/${q.need}`
    const t = Object.assign(document.createElement("b"), { textContent: title })
    const meta = document.createElement("div")
    meta.className = "meta"
    const arrow = Object.assign(document.createElement("span"), { className: "arrow" })
    const info = document.createElement("span")
    const mm = String(Math.floor(q.left / 60)).padStart(2, "0"), ss = String(q.left % 60).padStart(2, "0")
    if (q.hx === null || q.hx === undefined) {
      info.textContent = `Richtung unbekannt · ${mm}:${ss}`
    } else {
      const dx = q.hx - me.x, dy = q.hy - me.y
      arrow.textContent = "➤"
      arrow.style.transform = `rotate(${Math.atan2(dy, dx)}rad)`
      const dist = Math.round(Math.hypot(dx, dy) / 10) * 10
      info.textContent = `${compass(dx, dy)} · ca. ${dist} WE · ${mm}:${ss}`
    }
    meta.append(arrow, info)
    row.append(t, meta)
    rows.push(row)
  }
  questEl.replaceChildren(...rows)
}

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
      minimap.draw(me, state.ships, now, players.list, waypoints.list, state.ports)
      if (state.me && state.me.tn) territoryChanged(state.me.tn)
      renderer.players = players.list
      if (now - lastBoard > 250) {
        lastBoard = now
        renderBoard(me, state)
        renderQuests(me, state.me && state.me.q)
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
