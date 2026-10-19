// Photos are shrunk on the visitor's device before they are sent: the longest
// side to data-max pixels, as JPEG. A phone's 12-megapixel picture becomes a
// few hundred kilobytes, and the server never has to process an image.

async function shrink(file, max) {
  const bitmap = await createImageBitmap(file, {imageOrientation: "from-image"})
  const scale = Math.min(1, max / Math.max(bitmap.width, bitmap.height))
  const w = Math.round(bitmap.width * scale)
  const h = Math.round(bitmap.height * scale)
  const canvas = document.createElement("canvas")
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext("2d")
  ctx.fillStyle = "#fff"
  ctx.fillRect(0, 0, w, h)
  ctx.drawImage(bitmap, 0, 0, w, h)
  bitmap.close && bitmap.close()
  const blob = await new Promise(resolve => canvas.toBlob(resolve, "image/jpeg", 0.85))
  const name = (file.name || "photo").replace(/\.[^.]+$/, "") + ".jpg"
  return new File([blob], name, {type: "image/jpeg", lastModified: Date.now()})
}

export const ResizeUpload = {
  mounted() {
    const max = Number(this.el.dataset.max || 1600)
    const name = this.el.dataset.upload

    const take = async files => {
      const images = [...files].filter(f => f.type.startsWith("image/") || /\.(heic|heif)$/i.test(f.name))
      if (images.length === 0) return
      const label = document.getElementById(this.el.dataset.drop)
      label && label.classList.add("busy")
      try {
        const small = []
        for (const f of images) {
          try {
            small.push(await shrink(f, max))
          } catch (_e) {
            // A format this browser cannot read; send it as it is and let the server say no.
            small.push(f)
          }
        }
        this.upload(name, small)
      } finally {
        label && label.classList.remove("busy")
        this.el.value = ""
      }
    }

    this.el.addEventListener("change", () => take(this.el.files))

    const drop = document.getElementById(this.el.dataset.drop)
    if (drop) {
      drop.addEventListener("dragover", e => {
        e.preventDefault()
        drop.classList.add("over")
      })
      drop.addEventListener("dragleave", () => drop.classList.remove("over"))
      drop.addEventListener("drop", e => {
        e.preventDefault()
        drop.classList.remove("over")
        take(e.dataTransfer.files)
      })
    }
  },
}
