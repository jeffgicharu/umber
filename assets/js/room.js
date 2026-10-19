// The live room: the gavel's knock when a lot sells (only if the visitor turns
// sound on), and the spotlight's swing from one lot to the next.

let audio = null

function knock(times = 1) {
  audio = audio || new (window.AudioContext || window.webkitAudioContext)()
  const now = audio.currentTime
  for (let i = 0; i < times; i++) {
    const t = now + i * 0.16
    // A short, damped woody thud: a falling sine with a click of noise on top.
    const osc = audio.createOscillator()
    const gain = audio.createGain()
    osc.type = "sine"
    osc.frequency.setValueAtTime(190, t)
    osc.frequency.exponentialRampToValueAtTime(70, t + 0.12)
    gain.gain.setValueAtTime(0.0001, t)
    gain.gain.exponentialRampToValueAtTime(0.9, t + 0.004)
    gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.22)
    osc.connect(gain).connect(audio.destination)
    osc.start(t)
    osc.stop(t + 0.25)

    const buffer = audio.createBuffer(1, audio.sampleRate * 0.03, audio.sampleRate)
    const data = buffer.getChannelData(0)
    for (let j = 0; j < data.length; j++) data[j] = (Math.random() * 2 - 1) * Math.pow(1 - j / data.length, 3)
    const noise = audio.createBufferSource()
    const ng = audio.createGain()
    ng.gain.value = 0.35
    noise.buffer = buffer
    noise.connect(ng).connect(audio.destination)
    noise.start(t)
  }
}

export const Room = {
  mounted() {
    this.state = this.el.dataset.state
    this.lot = this.el.dataset.lot
    this.sound = false
    try {
      this.sound = localStorage.getItem("umber-sound") === "on"
    } catch (_e) {}
    this.button = this.el.querySelector("[data-sound]")
    this.paint()
    this.button && this.button.addEventListener("click", () => {
      this.sound = !this.sound
      try {
        localStorage.setItem("umber-sound", this.sound ? "on" : "off")
      } catch (_e) {}
      this.paint()
      if (this.sound) knock(1)
    })
  },
  updated() {
    const state = this.el.dataset.state
    const lot = this.el.dataset.lot
    if (state !== this.state) {
      if (state === "sold" && this.sound) knock(3)
      if (state === "passed" && this.sound) knock(1)
      if (state === "sold" && navigator.vibrate) navigator.vibrate(40)
    }
    if (lot && lot !== this.lot) this.swing()
    this.state = state
    this.lot = lot
    this.button = this.el.querySelector("[data-sound]")
    this.paint()
  },
  paint() {
    if (!this.button) return
    this.button.setAttribute("aria-pressed", String(this.sound))
    this.button.textContent = this.sound ? "Sound on" : "Sound off"
  },
  swing() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    const spot = this.el.querySelector(".spotlight")
    if (!spot) return
    spot.animate(
      [
        {opacity: 0.15, transform: "translateX(-14%) scale(0.9)"},
        {opacity: 1, transform: "translateX(0) scale(1)"},
      ],
      {duration: 1300, easing: "cubic-bezier(0.22, 1, 0.36, 1)"},
    )
  },
}
