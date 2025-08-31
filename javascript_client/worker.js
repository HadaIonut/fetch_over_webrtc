import * as encoding from "./encoding.js"

function encode(data, callbackMessage) {
  let fullEncodedMessage = ""
  for (let i = 0; i < data.length; i++) {
    fullEncodedMessage += data[i]
  }
  const res = encoding.textDecodeMessage(fullEncodedMessage)

  postMessage({ operation: callbackMessage, payload: res })
}

self.onmessage = (e) => {
  const { operation, payload } = e.data

  switch (operation) {
    case "encode":
      encode(payload, e.data.callbackMessage)
      break
    default:
      console.log("unknown operation received ", e)
      break
  }

}
