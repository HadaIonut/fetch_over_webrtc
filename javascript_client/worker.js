import * as encoding from "./encoding.js"

function encode(data) {
  let fullEncodedMessage = ""
  for (let i = 0; i < data.length; i++) {
    fullEncodedMessage += data[i]
  }
  const res = encoding.textDecodeMessage(fullEncodedMessage)

  postMessage(res)
}

async function addToDb(data) {
  const request = indexedDB.open("fetch_over_webrtc_frag_db", 1)

  const db = await new Promise((res) => {
    request.onupgradeneeded = (event) => {
      res(event.target.result)
    }

    request.onsuccess = (event) => {
      res(event.target.result)
    }
  })

  const objectStore = db.transaction(["frags"], "readwrite").objectStore("frags")

  objectStore.add(data)

  postMessage("ok")
}

self.onmessage = (e) => {
  const { operation, payload } = e.data

  switch (operation) {
    case "encode":
      encode(payload, e.data.callbackMessage)
      break
    case "addToDb":
      addToDb(payload)
      break
    default:
      console.log("unknown operation received ", e)
      break
  }

}
