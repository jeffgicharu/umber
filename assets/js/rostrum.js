// While a member of staff holds the rostrum, their console says so every five
// seconds. If it goes quiet (the tab closed, the phone locked), the automatic
// auctioneer picks the sale up after a short grace period.
export const Rostrum = {
  mounted() {
    this.timer = setInterval(() => {
      if (this.el.dataset.mine === "true" && document.visibilityState === "visible") this.pushEvent("heartbeat", {})
    }, 5000)
  },
  destroyed() {
    clearInterval(this.timer)
  },
}
