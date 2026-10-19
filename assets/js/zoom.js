// "Look closer": the work full screen at its largest size. Drag to move it,
// scroll or pinch to zoom, double-click to jump in or back, Escape to close.

export const ImageZoom = {
  mounted() {
    this.el.addEventListener("click", e => {
      if (e.target.closest("[data-zoom]")) this.open()
    })
  },

  open() {
    const img = this.el.querySelector("img")
    if (!img) return
    const src = biggest(img)

    const layer = document.createElement("div")
    layer.className = "zoom-layer"
    layer.setAttribute("role", "dialog")
    layer.setAttribute("aria-modal", "true")
    layer.setAttribute("aria-label", "The work, enlarged")
    layer.innerHTML = `<button type="button" class="zoom-close">Close</button><p class="zoom-hint">Drag to move · scroll or pinch to zoom</p>`
    const big = new Image()
    big.alt = img.alt
    big.src = src
    layer.appendChild(big)
    document.body.appendChild(layer)
    document.body.style.overflow = "hidden"
    const previous = document.activeElement
    layer.querySelector(".zoom-close").focus()

    let scale = 1
    let x = 0
    let y = 0
    let fit = 1
    const apply = () => {
      big.style.transform = `translate(${x}px, ${y}px) scale(${scale})`
    }
    const reset = () => {
      fit = Math.min(window.innerWidth / big.naturalWidth, window.innerHeight / big.naturalHeight) * 0.92
      scale = fit
      x = -big.naturalWidth * scale / 2
      y = -big.naturalHeight * scale / 2
      apply()
    }
    big.onload = reset
    if (big.complete) reset()

    const zoomAt = (factor, cx, cy) => {
      const next = Math.min(Math.max(scale * factor, fit), fit * 6)
      const k = next / scale
      // Keep the point under the pointer where it is.
      const ox = cx - window.innerWidth / 2
      const oy = cy - window.innerHeight / 2
      x = ox - (ox - x) * k
      y = oy - (oy - y) * k
      scale = next
      apply()
    }

    const pointers = new Map()
    let lastDist = null
    let moved = false

    layer.addEventListener("pointerdown", e => {
      if (e.target.closest(".zoom-close")) return
      layer.setPointerCapture(e.pointerId)
      pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
      moved = false
    })
    layer.addEventListener("pointermove", e => {
      if (!pointers.has(e.pointerId)) return
      const prev = pointers.get(e.pointerId)
      pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
      if (pointers.size === 2) {
        const [a, b] = [...pointers.values()]
        const dist = Math.hypot(a.x - b.x, a.y - b.y)
        if (lastDist) zoomAt(dist / lastDist, (a.x + b.x) / 2, (a.y + b.y) / 2)
        lastDist = dist
      } else {
        x += e.clientX - prev.x
        y += e.clientY - prev.y
        if (Math.abs(e.clientX - prev.x) + Math.abs(e.clientY - prev.y) > 2) moved = true
        apply()
      }
    })
    const up = e => {
      pointers.delete(e.pointerId)
      if (pointers.size < 2) lastDist = null
    }
    layer.addEventListener("pointerup", up)
    layer.addEventListener("pointercancel", up)
    layer.addEventListener("wheel", e => {
      e.preventDefault()
      zoomAt(e.deltaY < 0 ? 1.15 : 1 / 1.15, e.clientX, e.clientY)
    }, {passive: false})
    layer.addEventListener("dblclick", e => {
      if (scale > fit * 1.5) reset()
      else zoomAt(2.5, e.clientX, e.clientY)
    })

    const close = () => {
      layer.remove()
      document.body.style.overflow = ""
      document.removeEventListener("keydown", onKey)
      previous && previous.focus()
    }
    const onKey = e => {
      if (e.key === "Escape") close()
    }
    document.addEventListener("keydown", onKey)
    layer.querySelector(".zoom-close").addEventListener("click", close)
    layer.addEventListener("click", e => {
      if (e.target === layer && !moved) close()
    })
  },
}

function biggest(img) {
  const set = img.getAttribute("srcset")
  if (!set) return img.currentSrc || img.src
  const candidates = set.split(",").map(s => s.trim().split(/\s+/)).map(([u, w]) => ({u, w: parseInt(w, 10) || 0}))
  candidates.sort((a, b) => b.w - a.w)
  const avif = img.parentElement && img.parentElement.querySelector("source[type='image/avif']")
  const best = candidates[0].u
  // Prefer the AVIF of the same size where the browser shows AVIF.
  if (avif && img.currentSrc && img.currentSrc.endsWith(".avif")) return best.replace(/\.webp$/, ".avif")
  return best
}
