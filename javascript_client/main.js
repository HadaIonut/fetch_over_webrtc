import * as encoding from "./encoding.js"
/** @typedef {import('./types.d.ts').Header} Header */
/** @typedef {import('./types.d.ts').Body} Body */
/** @typedef {import('./types.d.ts').FetchMockParams} FetchMockParams */

function sendSocketRequest(data) {
  const reqId = crypto.randomUUID()
  const dataToSend = { ...data, requestId: reqId }

  socket.send(JSON.stringify(dataToSend))
  return new Promise((res, rej) => {
    const id = setTimeout(() => rej("timeout"), 10000)
    pending[reqId] = { res, rej, timeoutId: id }
  })
}

function sendJoinRoomMessage(roomId) {
  const joinRoomMessage = {
    type: "join",
    roomId: roomId
  }

  return sendSocketRequest(joinRoomMessage)
}

/**
 * @returns {Promise<RTCDataChannel>}
 */
async function startDataChannel(roomId) {
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


let socket
const pending = {}

async function startWebSocket(url) {
  socket = new WebSocket(url)
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
}

/** @type{RTCDataChannel} */
let dataChannel

export async function startConnection(roomId, webSocketUrl) {
  await startWebSocket(webSocketUrl)
  await sendJoinRoomMessage(roomId)
  dataChannel = await startDataChannel(roomId)

  dataChannel.addEventListener("message", (event) => {
    const data = event.data
    const { chunks, currentChunk, type, id, content } = encoding.binaryDecodeMessage(data)

    pending[id].parts[currentChunk] = content
    pending[id].partsReceived++
    pending[id].type = type

    if (pending[id].partsReceived !== chunks) return

    const [header, body] = encoding.textDecodeMessage(pending[id].parts.join(""))

    pending[id].res({ header, body })
  })
}

/**
  * @param {Header} header 
  * @param {Body} body
  * @returns {Promise<unknown>}
  */
export async function sendMessage(header, body = "") {
  const [payload, requestType] = await encoding.textEncodeMessage(header, body)
  const requestId = crypto.randomUUID()
  const encoded = encoding.binaryEncodeMessage(payload, requestType, requestId)

  encoded.forEach(p => dataChannel.send(p))

  return new Promise((res, rej) => {
    const timeoutId = setTimeout(() => rej("timeout"), 10000)
    pending[requestId] = { res, rej, timeoutId, parts: [], type: "", partsReceived: 0 }
  })
}

/**
 * @param {string} url 
 * @param {FetchMockParams} params
 */
export async function fetchOverWebRTC(url, params) {
  const method = params.method ?? 'GET'
  const fallbackContentType = method === 'GET' ? null : 'application/json'

  const requestHeaders = params.headers ?? {}
  const contentType = requestHeaders["Content-Type"] ?? requestHeaders["content-type"]

  delete requestHeaders["Content-Type"]
  delete requestHeaders["content-type"]

  /** @type(Header) */
  const header = {
    route: url,
    requestHeaders: requestHeaders,
    contentType: contentType ?? fallbackContentType,
    requestType: method
  }

  const body = params.body

  return await sendMessage(header, body)
}

let override = false

export function overrideFetch() {
  override = true
}

const oldFetch = window.fetch

window.fetch = (url, params = {}, forceWebRTC) => {
  const useRTC = forceWebRTC === undefined ? overrideFetch : forceWebRTC

  if (useRTC) return fetchOverWebRTC(url, params)
  return oldFetch(url, params)
}

