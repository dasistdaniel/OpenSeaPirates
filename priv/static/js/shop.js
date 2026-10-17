// Hafen-Oberfläche: Schiffe, Ausrüstung, Munition, Werft, Bank. Zeigt, was der Server schickt
// (`{"t":"shop", ...}`), und sendet Käufe zurück. Die Preise und Regeln liegen allein im Server.

import { NATIONS, NATION_ORDER, standing, STANDING_LABEL, STANDING_COLOR, signed } from "./nations.js"

const COLORS = ["yellow", "blue", "red", "green", "black", "white"]

const ERRORS = {
  no_gold: "Zu wenig Gold.",
  max_level: "Höchste Stufe erreicht.",
  same_class: "Du fährst dieses Schiff schon.",
  full: "Nichts zu tun.",
  no_bank_gold: "So viel liegt nicht auf der Bank.",
  amount: "Ungültiger Betrag.",
  not_docked: "Du bist nicht angedockt.",
  too_fast: "Zu schnell zum Andocken.",
  no_port: "Kein Hafen in Reichweite.",
  docked: "Du bist schon angedockt.",
  hostile: "Dieser Hafen verkauft dir nichts mehr.",
  not_wanted: "Du wirst hier nicht gesucht.",
  unknown: "Unbekannt.",
}

export class Shop {
  constructor(root, net) {
    this.root = root
    this.net = net
    this.color = 0
    this.open = false
    root.addEventListener("click", (e) => this.click(e))
  }

  setColor(c) {
    this.color = c
  }

  // Server-Nachricht verarbeiten; gibt zurück, ob der Hafen jetzt offen ist
  update(view) {
    if (view.error && !view.open) {
      this.toast(ERRORS[view.error] || view.error, true)
      return this.open
    }
    this.open = !!view.open
    this.root.hidden = !this.open
    if (!this.open) return false
    this.render(view)
    if (view.error) this.toast(ERRORS[view.error] || view.error, true)
    return true
  }

  toast(text, bad) {
    let el = document.getElementById("toast")
    if (!el) {
      el = document.createElement("div")
      el.id = "toast"
      document.body.appendChild(el)
    }
    el.textContent = text
    el.className = bad ? "bad" : ""
    el.hidden = false
    clearTimeout(this.timer)
    this.timer = setTimeout(() => (el.hidden = true), 2200)
  }

  click(e) {
    const b = e.target.closest("[data-act]")
    if (!b || b.disabled) return
    const { act, id, op, amount } = b.dataset
    if (act === "undock") this.net.send({ t: "undock" })
    else if (act === "class") this.net.send({ t: "buy", what: "class", id })
    else if (act === "upgrade") this.net.send({ t: "buy", what: "upgrade", id })
    else if (act === "ammo") this.net.send({ t: "buy", what: "ammo", id })
    else if (act === "repair") this.net.send({ t: "buy", what: "repair" })
    else if (act === "atone") this.net.send({ t: "buy", what: "atone" })
    else if (act === "bank") this.net.send({ t: "bank", op, amount: amount === "all" ? "all" : Number(amount) })
  }

  // Ruf bei allen fünf Nationen (aus `v.reps`, Reihenfolge wie NATION_ORDER)
  repsHtml(v) {
    const items = (v.reps || [])
      .map((value, i) => {
        const key = NATION_ORDER[i]
        const st = standing(value)
        return `<span class="rep"><img src="/images/flags/${key}.png" alt="" />${NATIONS[key].name} <b style="color:${STANDING_COLOR[st]}">${signed(value)}</b> <small>${STANDING_LABEL[st]}</small></span>`
      })
      .join("")
    return `<div class="reps">${items}</div>`
  }

  // Gesucht bei der Nation des Hafens: nichts wird verkauft, nur die Wiedergutmachung
  renderHostile(v) {
    const nation = NATIONS[v.nation] ? NATIONS[v.nation].name : ""
    const can = v.gold >= v.atone.cost
    this.root.innerHTML = `
      <div class="panel">
        <header>
          <div><span class="kicker">Hafen · ${nation}</span><h2>⚓ ${v.port}</h2></div>
          <div class="money"><span>🪙 ${v.gold}</span></div>
          <button class="ghost" data-act="undock">Ablegen (F)</button>
        </header>
        <div class="hostile">
          <h3>${nation} verkauft dir nichts mehr</h3>
          <p>Du bist hier <b>gesucht</b> (Ruf ${signed(v.rep)}). Schiffe, Ausrüstung, Munition, Reparatur und Bank sind gesperrt,
            und die Schutzzone gilt für dich nicht. Zahle Wiedergutmachung, um wieder Handel zu treiben.</p>
          <div class="row"><div class="grow"><b>Wiedergutmachung</b><small>Ruf bei ${nation} ${signed(v.atone.gain)}</small></div>
            <button data-act="atone" ${can ? "" : "disabled"}>${v.atone.cost} 🪙</button></div>
          ${can ? "" : `<p class="muted">Dir fehlen ${v.atone.cost - v.gold} Gold. Der Ruf erholt sich auch von selbst, langsam.</p>`}
          ${this.repsHtml(v)}
        </div>
      </div>`
  }

  render(v) {
    if (v.hostile) return this.renderHostile(v)
    const color = COLORS[this.color % COLORS.length]
    const classes = v.classes
      .map((c) => {
        const can = !c.current && v.gold >= c.cost
        return `
        <div class="card ${c.current ? "current" : ""}">
          <img src="/images/ships/${c.id}_${color}.png" alt="" />
          <div class="body">
            <h4>${c.name}</h4>
            <p class="blurb">${c.blurb}</p>
            <p class="stats">❤ ${c.hp} · 💥 ${c.cannons} je Seite · ⛵ ${c.speed}% · ↻ ${c.turn}%</p>
          </div>
          ${
            c.current
              ? '<span class="tag">Dein Schiff</span>'
              : `<button data-act="class" data-id="${c.id}" ${can ? "" : "disabled"}>${c.cost} 🪙</button>`
          }
        </div>`
      })
      .join("")

    const fmt = (slot, n) => (slot === "hull" ? `+${n} HP` : slot === "cannons" ? `×${n.toFixed(1)}` : `×${n.toFixed(2)}`)
    const upgrades = v.upgrades
      .map((u) => {
        const pips = Array.from({ length: u.max }, (_, i) => `<i class="${i < u.level ? "on" : ""}"></i>`).join("")
        const maxed = u.price === null
        return `
        <div class="row">
          <div class="grow">
            <b>${u.label}</b> <span class="pips">${pips}</span>
            <small>${u.what}: ${fmt(u.slot, u.now)}${maxed ? "" : " → " + fmt(u.slot, u.next)}</small>
          </div>
          ${maxed ? '<span class="tag">Max</span>' : `<button data-act="upgrade" data-id="${u.slot}" ${v.gold >= u.price ? "" : "disabled"}>${u.price} 🪙</button>`}
        </div>`
      })
      .join("")

    const ammo = v.ammo
      .map(
        (a) => `
        <div class="row">
          <div class="grow"><b>${a.label}</b> <span class="muted">${a.have}/${a.max}</span><small>${a.what}</small></div>
          <button data-act="ammo" data-id="${a.kind}" ${v.gold >= a.price && a.have < a.max ? "" : "disabled"}>${a.pack}× · ${a.price} 🪙</button>
        </div>`
      )
      .join("")

    this.root.innerHTML = `
      <div class="panel">
        <header>
          <div><span class="kicker">Hafen</span><h2>⚓ ${v.port}</h2></div>
          <div class="money"><span>🪙 ${v.gold}</span><span class="muted">Bank ${v.bank}</span></div>
          <button class="ghost" data-act="undock">Ablegen (F)</button>
        </header>
        <div class="cols">
          <section><h3>Schiffe <small>Inzahlungnahme 50 %</small></h3><div class="cards">${classes}</div></section>
          <section>
            <h3>Ausrüstung</h3>${upgrades}
            <h3>Munition <small>Tasten 1–3 im Gefecht</small></h3>${ammo}
            <h3>Werft</h3>
            <div class="row"><div class="grow"><b>Reparatur</b><small>${v.hp} / ${v.max_hp} HP · ${v.repair.per_hp} Gold je HP</small></div>
              <button data-act="repair" ${v.repair.cost > 0 && v.gold >= v.repair.per_hp ? "" : "disabled"}>${v.repair.cost} 🪙</button></div>
            <h3>Ruf</h3>${this.repsHtml(v)}
            <h3>Bank <small>sicher vor Verlust beim Tod</small></h3>
            <div class="row bank">
              <button data-act="bank" data-op="deposit" data-amount="50" ${v.gold >= 50 ? "" : "disabled"}>+50</button>
              <button data-act="bank" data-op="deposit" data-amount="all" ${v.gold > 0 ? "" : "disabled"}>Alles einzahlen</button>
              <button data-act="bank" data-op="withdraw" data-amount="50" ${v.bank >= 50 ? "" : "disabled"}>−50</button>
              <button data-act="bank" data-op="withdraw" data-amount="all" ${v.bank > 0 ? "" : "disabled"}>Alles abheben</button>
            </div>
          </section>
        </div>
      </div>`
  }
}
