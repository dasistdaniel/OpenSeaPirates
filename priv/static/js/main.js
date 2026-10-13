// Einstieg: verbindet Netz, Gelände, Eingabe, Darstellung und Ton

import { Net } from "./net.js"
import { Chunks } from "./chunks.js"
import { Input } from "./input.js"
import { Renderer } from "./render.js"
import { Snapshots } from "./snapshots.js"
import { Minimap } from "./minimap.js"
import { Sound } from "./audio.js"

const NAME_KEY = "osp-name"
const $ = (id) => document.getElementById(id)

const statusEl = $("status")
const hudEl = $("hud")
const posEl = $("hud-pos")

const snaps = new Snapshots()
const sound = new Sound()
const names = new Map() // id -> Name (für Meldungen, auch von Schiffen außer Sicht)
let joined = false
let myId = null

const net = new Net({
  onWelcome(msg) {
    chunks.configure(msg)
    myId = msg.you
    joined = true
    input.enabled = true
    $("join").hidden = true
    hudEl.hidden = false
  },
  onSnap(msg) {
    snaps.push(msg)
    for (const s of msg.ships) names.set(s.i, s.n)
    for (const ev of msg.ev || []) handleEvent(ev)
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
  onUse: () => net.send({ t: "use" }),
  onMute: () => sound.toggle(),
})
const renderer = new Renderer($("game"), chunks)
const minimap = new Minimap($("minimap"), chunks)

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
    renderer.effect({
      t: "text", x, y, life: 800, text: "-" + amount, color: victim === myId ? "#fca5a5" : "#fde68a",
    })
    sound.play("hit", victim === myId || by === myId ? 1 : 0.35)
  } else if (kind === "kill") {
    const [, killer, victim, x, y] = ev
    renderer.effect({ t: "expl", x, y, life: 800, size: 2.0 })
    renderer.killFeed(`${killer ? nm(killer) : "Riff"} ⚓ ${nm(victim)}`, killer === myId || victim === myId)
    sound.play("kill", 1)
  } else if (kind === "splash") {
    renderer.effect({ t: "ring", x: ev[1], y: ev[2], life: 400 })
  } else if (kind === "pickup") {
    if (ev[1] === myId) sound.play("pickup", 1)
  } else if (kind === "power") {
    if (ev[1] === myId) sound.play("power", 1)
  } else if (kind === "respawn") {
    renderer.effect({ t: "ring", x: ev[2], y: ev[3], life: 700 })
  }
}

// --- Beitreten ----------------------------------------------------------------------
const nameInput = $("name")
try { nameInput.value = localStorage.getItem(NAME_KEY) || "" } catch (_) {}
nameInput.focus()

$("join-form").addEventListener("submit", (e) => {
  e.preventDefault()
  const name = nameInput.value.trim()
  try { localStorage.setItem(NAME_KEY, name) } catch (_) {}
  net.connect(name)
  $("join-button").disabled = true
})

// --- Schleife -----------------------------------------------------------------------
const LOAD_RADIUS_WE = 48 // Chunks in diesem Umkreis laden (Bildschirm ± Minikarte)

function frame(now) {
  requestAnimationFrame(frame)
  const state = snaps.sample(now)
  renderer.draw(state, now)

  if (state && joined) {
    const me = state.ships.find((s) => s.i === state.you)
    if (me) {
      chunks.ensureAround(me.x, me.y, LOAD_RADIUS_WE)
      minimap.draw(me, state.ships, now)
      posEl.textContent =
        `x ${me.x.toFixed(0)}  y ${me.y.toFixed(0)}  ·  Tempo ${me.v.toFixed(1)}  ·  ` +
        `${state.ships.length - 1} Schiffe in der Nähe`
    }
  }
}

requestAnimationFrame(frame)
