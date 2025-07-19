let db

export const startDatabase = () => {
  if (db) return
  return new Promise((res, rej) => {
    const request = window.indexedDB.open("fetch_over_webrtc_frag_db", 1)

    request.onupgradeneeded = (event) => {
      db = event.target.result;

      const objectStore = db.createObjectStore("frags", { keyPath: "fragId", autoIncrement: false })
      objectStore.createIndex("fragId", "fragId", { unique: true })

      objectStore.transaction.oncomplete = (event) =>
        res()

      objectStore.transaction.onerror = (event) => rej(event)
    }

    request.onerror = (event) => rej(event)

    request.onsuccess = (event) => {
      res()
      db = event.target.result
    }
  })
}

export const writeFrags = (data) => {
  const objectStore = db.transaction(["frags"], "readwrite").objectStore("frags")

  objectStore.add(data)
}
