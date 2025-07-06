import * as encoding from "./encoding.js"
/** @typedef {import('./types.d.ts').Header} Header */
/** @typedef {import('./types.d.ts').Body} Body */

function sendSocketRequest(data) {
  const reqId = crypto.randomUUID()
  const dataToSend = { ...data, requestId: reqId }

  socket.send(JSON.stringify(dataToSend))
  return new Promise((res, rej) => {
    const id = setTimeout(() => rej("timeout"), 10000)
    pending[reqId] = { res, rej, timeoutId: id }
  })
}

export function sendJoinRoomMessage(roomId) {
  const joinRoomMessage = {
    type: "join",
    roomId: roomId
  }

  return sendSocketRequest(joinRoomMessage)
}

/**
 * @returns {Promise<RTCDataChannel>}
 */
export async function startDataChannel(roomId) {
  peerConnection = new RTCPeerConnection()
  const dataChannel = peerConnection.createDataChannel("ligma")
  dataChannel.binaryType = 'arraybuffer'
  const offer = await peerConnection.createOffer()
  await peerConnection.setLocalDescription(offer)
  const message = {
    type: "offer",
    roomId: roomId,
    sdpCert: JSON.stringify(offer)
  }

  await sendSocketRequest(message)

  return new Promise((res) => {
    dataChannel.addEventListener("open", () => {
      console.log("channel opened")
      res(dataChannel)
    })
  })
}

async function handleUserOfferReply(cert) {
  const jsonCert = JSON.parse(cert)
  await peerConnection.setRemoteDescription(jsonCert)
}

async function handleIceCandidate(candidate) {
  const candidateJson = JSON.parse(candidate)
  await peerConnection.addIceCandidate(candidateJson)
}

/** @type(RTCPeerConnection) */
let peerConnection

const socket = new WebSocket("ws://127.0.0.1:3000/ws")

const pending = {}

socket.addEventListener("message", (event) => {
  let data
  try {
    data = JSON.parse(event.data)
  } catch (e) {
    console.log("something went wrong trying to decode: " + event.data)
    return
  }
  if (!pending[data.requestId]) {
    switch (data.type) {
      case "userOfferReply":
        handleUserOfferReply(data.sdpCert)
        break;
      case "ICECandidate":
        handleIceCandidate(data.ICECandidate)
        break;
      default:
        console.log("non response message: ", data)
        break
    }
    return
  }
  pending[data.requestId].res(data)
  clearTimeout(pending[data.requestId].timeoutId)
  delete pending[data.requestId]
})

await new Promise((res) => {
  socket.addEventListener("open", _ => res())
})

const roomId = "E4086473-1622-4C62-971E-67E9F5714FDE"

console.log(await sendJoinRoomMessage(roomId))
const datachannel = await startDataChannel(roomId)

datachannel.addEventListener("message", (event) => {
  const data = event.data
  const { chunks, currentChunk, type, id, content } = encoding.binaryDecodeMessage(data)

  console.log(Object.keys(pending))
  console.log(id)

  pending[id].parts[currentChunk] = content
  pending[id].partsReceived++
  pending[id].type = type

  if (pending[id].partsReceived !== chunks) return

  const [header, body] = encoding.textDecodeMessage(pending[id].parts.join(""))

  pending[id].res({ header, body })
})

/**
  * @param {Header} header 
  * @param {Body} body
  * @returns {Promise<unknown>}
  */
export async function sendMessage(header, body) {
  const [payload, requestType] = await encoding.textEncodeMessage(header, body)
  const requestId = crypto.randomUUID()
  const encoded = encoding.binaryEncodeMessage(payload, requestType, requestId)

  encoded.forEach(p => datachannel.send(p))

  return new Promise((res, rej) => {
    const timeoutId = setTimeout(() => rej("timeout"), 10000)
    pending[requestId] = { res, rej, timeoutId, parts: [], type: "", partsReceived: 0 }
  })
}

console.log(await sendMessage({ route: "https://google.com", requestType: "GET" }, ""))
