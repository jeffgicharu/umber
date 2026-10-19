// Every countdown on a page runs from the server's clock, not the visitor's.
// Each one carries the server's time when it was rendered; the difference to
// this machine's clock is kept and applied to every tick.

export const ServerClock = {
  delta: 0,
  samples: 0,
  learn(serverIso) {
    const server = Date.parse(serverIso)
    if (Number.isNaN(server)) return
    const d = server - Date.now()
    // A slow delivery makes the server look further behind than it is, so the
    // largest difference seen is the closest to the truth.
    this.delta = this.samples === 0 ? d : Math.max(this.delta, d)
    this.samples += 1
  },
  now() {
    return Date.now() + this.delta
  },
  offset() {
    return this.delta
  },
}

export function remaining(seconds) {
  if (seconds <= 0) return "0:00"
  const pad = n => String(n).padStart(2, "0")
  if (seconds < 60) return `0:${pad(seconds)}`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${pad(seconds % 60)}s`
  return `${Math.floor(seconds / 3600)}h ${pad(Math.floor((seconds % 3600) / 60))}m`
}

const ticking = new Set()
let timer = null

function tickAll() {
  ticking.forEach(hook => hook.render())
}

function start(hook) {
  ticking.add(hook)
  if (!timer) timer = setInterval(tickAll, 250)
}

function stop(hook) {
  ticking.delete(hook)
  if (ticking.size === 0 && timer) {
    clearInterval(timer)
    timer = null
  }
}

export const Countdown = {
  mounted() {
    this.read()
    start(this)
    this.render()
  },
  updated() {
    this.read()
    this.render()
  },
  destroyed() {
    stop(this)
  },
  read() {
    if (this.el.dataset.now) ServerClock.learn(this.el.dataset.now)
    const at = Date.parse(this.el.dataset.at)
    // A later closing time means the lot was extended by a late bid.
    if (this.at && at > this.at + 1000) this.extended()
    this.at = at
  },
  render() {
    const left = Math.max(0, Math.round((this.at - ServerClock.now()) / 1000))
    const prefix = this.el.dataset.prefix ? this.el.dataset.prefix + " " : ""
    const text = left === 0 ? "Closing" : prefix + remaining(left)
    if (this.el.textContent !== text) this.el.textContent = text
    const urgency = left <= 60 ? "now" : left <= 300 ? "soon" : "later"
    if (this.el.dataset.urgency !== urgency) this.el.dataset.urgency = urgency
  },
  extended() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    const badge = document.createElement("span")
    badge.className = "extended-badge"
    badge.textContent = "+2:00"
    badge.setAttribute("aria-hidden", "true")
    this.el.appendChild(badge)
    badge.animate(
      [
        {opacity: 0, transform: "translateY(10px) scale(0.8)"},
        {opacity: 1, transform: "translateY(-4px) scale(1.06)", offset: 0.25},
        {opacity: 1, transform: "translateY(-6px) scale(1)", offset: 0.75},
        {opacity: 0, transform: "translateY(-16px)"},
      ],
      {duration: 1800, easing: "cubic-bezier(0.22, 1, 0.36, 1)"},
    ).onfinish = () => badge.remove()
  },
}
