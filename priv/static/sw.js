// Umber's service worker: shows bidding notices and opens the lot when one is tapped.

self.addEventListener("push", event => {
  let data = {title: "Umber", body: "", url: "/"}
  try {
    data = Object.assign(data, event.data ? event.data.json() : {})
  } catch (_e) {}

  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: "/images/brand/icon-192.png",
      badge: "/images/brand/badge-96.png",
      tag: data.tag,
      renotify: true,
      data: {url: data.url},
    }),
  )
})

self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || "/"
  event.waitUntil(
    self.clients.matchAll({type: "window", includeUncontrolled: true}).then(list => {
      for (const client of list) {
        if (client.url.startsWith(self.location.origin) && "focus" in client) {
          client.navigate(url)
          return client.focus()
        }
      }
      return self.clients.openWindow(url)
    }),
  )
})
