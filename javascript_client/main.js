import { startDatabase, writeFrags } from "./database.js"
import * as encoding from "./encoding.js"
/** @typedef {import('./types.d.ts').Header} Header */
/** @typedef {import('./types.d.ts').Body} Body */
/** @typedef {import('./types.d.ts').FetchMockParams} FetchMockParams */

/** @type{RTCDataChannel} */
let dataChannel
let override = false
const oldFetch = window.fetch
/** @type{RTCPeerConnection} */
let peerConnection
let socket

const pending = {}

window.fetch = (url, params = {}, forceWebRTC) => {
  const useRTC = forceWebRTC === undefined ? overrideFetch : forceWebRTC

  if (useRTC) return fetchOverWebRTC(url, params)
  return oldFetch(url, params)
}

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

/**
 * @param {MessageEvent} event 
 */
function handleDataChannelMessage(event) {
  const data = event.data
  const { chunks, hasFrags, currentChunk, type, id, content, fragId } = encoding.binaryDecodeMessage(data)

  const [textContent, frags] = content.split("\n---frags---\n")
  let joinedParts = ""

  if (frags) {
    pending[id].parts[currentChunk] = textContent
    pending[id].parts_done = true
    pending[id].parts_returned = false

    joinedParts = pending[id].parts.join("")

    pending[id].expected_frags = joinedParts.match(/src="(.*?)"/g).length

    if (frags.trim()) pending[id].frags.push(frags)
  } else if (!pending[id].parts_done) {
    pending[id].parts[currentChunk] = textContent
  } else {
    if (pending[id].frags[fragId]) pending[id].frags[fragId] += textContent
    else pending[id].frags[fragId] = textContent

    if (textContent.endsWith("\r\n")) {
      writeFrags({ content: pending[id].frags[fragId], fragId })

      delete pending[id].frags[fragId]
      pending[id].rec_frags++

    }
  }

  pending[id].partsReceived++
  pending[id].type = type

  const allChunksReceived = pending[id].partsReceived === chunks
  const allPartsRecieved = pending[id].parts_done
  const returnedParts = pending[id].parts_returned

  if (pending[id].rec_frags === pending[id].expected_frags && pending[id].rec_frags !== 0) {
    delete pending[id]
    return
  }
  if (!allChunksReceived && !(allPartsRecieved && returnedParts)) return

  pending[id].parts_returned = true

  const [header, body] = encoding.textDecodeMessage(joinedParts)

  pending[id].res({ header, body })

  if (frags === undefined && !pending[id].parts_done) delete pending[id]
}

export async function startConnection(roomId, webSocketUrl) {
  startDatabase()
  await startWebSocket(webSocketUrl)
  await sendJoinRoomMessage(roomId)
  dataChannel = await startDataChannel(roomId)

  dataChannel.addEventListener("message", handleDataChannelMessage)
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
    pending[requestId] = { res, rej, timeoutId, parts: [], type: "", partsReceived: 0, partsDone: false, frags: {}, expected_frags: 0, rec_frags: 0 }
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

export function overrideFetch() {
  override = true
}
