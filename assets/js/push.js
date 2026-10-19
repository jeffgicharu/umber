// Turning phone and computer notifications on and off for this device.

function keyBytes(base64url) {
  const pad = "=".repeat((4 - (base64url.length % 4)) % 4)
  const raw = atob((base64url + pad).replace(/-/g, "+").replace(/_/g, "/"))
  return Uint8Array.from([...raw].map(c => c.charCodeAt(0)))
}

export const Push = {
  async mounted() {
    this.on = this.el.querySelector("[data-push-on]")
    this.off = this.el.querySelector("[data-push-off]")
    this.status = this.el.querySelector("[data-push-status]")

    const supported = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
    if (!supported || this.el.dataset.ready !== "true") {
      this.on.disabled = true
      this.say(supported ? "Notifications are not available yet." : "This browser cannot show notifications from websites. On an iPhone, add Umber to your home screen first.")
      return
    }

    this.registration = await navigator.serviceWorker.register("/sw.js")
    await this.refresh()

    this.on.addEventListener("click", () => this.subscribe())
    this.off.addEventListener("click", () => this.unsubscribe())
  },

  say(text) {
    if (this.status) this.status.textContent = text
  },

  async refresh() {
    const sub = await this.registration.pushManager.getSubscription()
    this.on.hidden = !!sub
    this.off.hidden = !sub
    if (Notification.permission === "denied") {
      this.on.disabled = true
      this.say("Notifications are blocked for this site in your browser's settings.")
    } else {
      this.say(sub ? "Notifications are on for this device." : "")
    }
  },

  async subscribe() {
    this.on.disabled = true
    try {
      const permission = await Notification.requestPermission()
      if (permission !== "granted") {
        this.say("Notifications were not allowed.")
        return
      }
      const sub = await this.registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: keyBytes(this.el.dataset.key),
      })
      this.pushEvent("push-subscribe", sub.toJSON(), () => this.refresh())
    } catch (e) {
      this.say("This browser could not turn notifications on.")
    } finally {
      this.on.disabled = false
    }
  },

  async unsubscribe() {
    const sub = await this.registration.pushManager.getSubscription()
    if (sub) {
      const endpoint = sub.endpoint
      await sub.unsubscribe()
      this.pushEvent("push-unsubscribe", {endpoint}, () => this.refresh())
    }
  },
}
