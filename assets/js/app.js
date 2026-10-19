import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/umber"
import {Countdown, ServerClock} from "./countdown"
import {Odometer} from "./odometer"
import {Room} from "./room"
import {ImageZoom} from "./zoom"
import {ResizeUpload} from "./resize_upload"
import {Push} from "./push"
import {Rostrum} from "./rostrum"

const FlashTimer = {
  mounted() {
    this.timer = setTimeout(() => this.el.querySelector("button")?.click(), 6000)
  },
  destroyed() {
    clearTimeout(this.timer)
  },
}

// Page-to-page moves morph the shared picture of a work; ordinary live
// updates (a new bid, a ticking clock) are applied at once, untouched.
let navigating = false
window.addEventListener("phx:page-loading-start", e => {
  navigating = e.detail && (e.detail.kind === "redirect" || e.detail.kind === "patch")
})

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)")

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({_csrf_token: csrfToken, tz_offset: ServerClock.offset()}),
  hooks: {...colocatedHooks, Countdown, Odometer, Room, ImageZoom, ResizeUpload, Push, Rostrum, FlashTimer},
  dom: {
    onDocumentPatch(start) {
      if (navigating && document.startViewTransition && !reducedMotion.matches) {
        navigating = false
        document.startViewTransition(() => start())
      } else {
        navigating = false
        start()
      }
    },
  },
})

// A thin bar along the top while a page loads, in the house's brass.
let barTimer
const bar = document.createElement("div")
bar.className = "page-bar"
document.addEventListener("DOMContentLoaded", () => document.body.appendChild(bar))
window.addEventListener("phx:page-loading-start", () => {
  clearTimeout(barTimer)
  barTimer = setTimeout(() => bar.classList.add("on"), 200)
})
window.addEventListener("phx:page-loading-stop", () => {
  clearTimeout(barTimer)
  bar.classList.remove("on")
})

// Close the phone menu after choosing a link in it.
document.addEventListener("click", e => {
  const link = e.target.closest("#mobile-menu a")
  if (link) {
    document.getElementById("mobile-menu")?.classList.remove("open")
    document.querySelector(".menu-button")?.setAttribute("aria-expanded", "false")
  }
})

liveSocket.connect()
window.liveSocket = liveSocket
