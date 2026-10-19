// Amounts that roll into place like the numbers on a board: each digit is a
// column of 0 to 9 that slides to its new value. Commas and letters stay put.
//
//   <span phx-hook="Odometer" data-value="1250000" data-prefix="KES "></span>

const format = n => Number(n).toLocaleString("en-GB")
const reduce = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches

export const Odometer = {
  mounted() {
    this.value = this.el.dataset.value
    this.build(this.text(this.value), false)
  },
  updated() {
    const next = this.el.dataset.value
    if (next === this.value) return
    const rising = Number(next) > Number(this.value)
    this.value = next
    this.build(this.text(next), !reduce())
    if (rising && !reduce()) {
      this.el.animate([{color: "var(--brass-hi)"}, {color: "inherit"}], {duration: 1400, easing: "ease-out"})
    }
  },
  text(value) {
    if (value === "" || value === undefined || value === null) return this.el.dataset.empty || "—"
    return (this.el.dataset.prefix || "") + format(value)
  },
  build(text, animate) {
    const label = text
    this.el.setAttribute("aria-label", label)
    const old = this.el.querySelector(".odo")
    const wrap = document.createElement("span")
    wrap.className = "odo"
    wrap.setAttribute("aria-hidden", "true")

    // Digits are counted from the right, so a new leading digit slides in
    // without moving the ones that did not change.
    const chars = [...text]
    const digitsFromRight = chars.map((c, i) => chars.slice(i + 1).filter(x => /\d/.test(x)).length)
    const oldDigits = old ? [...old.querySelectorAll(".odo-col")].reduce((acc, col) => ((acc[col.dataset.place] = col.dataset.digit), acc), {}) : {}

    chars.forEach((c, i) => {
      if (/\d/.test(c)) {
        const place = digitsFromRight[i]
        const col = document.createElement("span")
        col.className = "odo-col"
        col.dataset.place = place
        col.dataset.digit = c
        const strip = document.createElement("span")
        strip.className = "odo-strip"
        for (let d = 0; d <= 9; d++) {
          const s = document.createElement("span")
          s.textContent = d
          strip.appendChild(s)
        }
        col.appendChild(strip)
        const from = oldDigits[place]
        strip.style.transform = `translateY(-${Number(c) * 10}%)`
        if (animate && from !== undefined && from !== c) {
          strip.animate([{transform: `translateY(-${Number(from) * 10}%)`}, {transform: `translateY(-${Number(c) * 10}%)`}], {
            duration: 700 + place * 60,
            easing: "cubic-bezier(0.22, 1, 0.36, 1)",
          })
        } else if (animate && from === undefined) {
          col.animate([{opacity: 0, transform: "translateY(40%)"}, {opacity: 1, transform: "none"}], {duration: 500, easing: "ease-out"})
        }
        wrap.appendChild(col)
      } else {
        const s = document.createElement("span")
        s.className = "odo-sep"
        // A plain space would collapse inside the flex row.
        s.textContent = c === " " ? " " : c
        wrap.appendChild(s)
      }
    })

    this.el.replaceChildren(wrap)
  },
}
