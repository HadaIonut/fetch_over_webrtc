/** @type(IDBDatabase) */
let db

const fragListeners = []

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
      db = event.target.result
      const result = db.transaction(["frags"], "readwrite").objectStore("frags").clear()
      result.onsuccess = () => res()
    }
  })
}

export const writeFrags = (data) => {
  const objectStore = db.transaction(["frags"], "readwrite").objectStore("frags")

  objectStore.add(data)

  fragListeners.forEach(listener => listener(data.fragId))
}

/** 
 * @returns {IDBRequest}
 */
export const readFrag = (fragId) => {
  const objectStore = db.transaction(["frags"], "readonly").objectStore("frags")
  return objectStore.get(fragId)
}

/**
 * @type {(fragId: string) => void} callback
 */
export const listenForFrag = (callback) => {
  fragListeners.push(callback)
} 
