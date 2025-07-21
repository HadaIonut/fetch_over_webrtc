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
let currentRoomId

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

function decodeSocketMessage(event) {
  try {
    return JSON.parse(event.data)
  } catch (e) {
    console.log("something went wrong trying to decode: " + event.data)
  }

  return {}
}

function handleSocketMessage(event) {
  let data = decodeSocketMessage(event)

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
}

async function startWebSocket(url) {
  socket = new WebSocket(url)
  socket.addEventListener("message", handleSocketMessage)

  await new Promise((res) => socket.addEventListener("open", _ => res()))
}

function updateFrag(pendingId, fragId, textContent) {
  if (pending[pendingId].frags[fragId]) pending[pendingId].frags[fragId] += textContent
  else pending[pendingId].frags[fragId] = textContent
}

function handleFragEnding(pendingId, fragId, textContent) {
  if (!textContent.endsWith("\r\n")) return

  writeFrags({
    content: pending[pendingId].frags[fragId], fragId
  })

  delete pending[pendingId].frags[fragId]
  pending[pendingId].rec_frags++
}

function isMainMessageDone(pendingId, chunks) {
  const allChunksReceived = pending[pendingId].partsReceived === chunks
  const allPartsRecieved = pending[pendingId].parts_done
  const returnedParts = pending[pendingId].parts_returned

  return allChunksReceived || (allPartsRecieved && returnedParts)
}

function decodeMainMessage(pendingId, hasFrags) {
  pending[pendingId].parts_returned = true
  const [header, body] = encoding.textDecodeMessage(pending[pendingId].parts.join(""))
  pending[pendingId].res({ header, body, hasFrags })
}

/**
 * @param {MessageEvent} event 
 */
function handleDataChannelMessage(event) {
  const data = event.data
  const { chunks, _, currentChunk, type, id, content, fragId } = encoding.binaryDecodeMessage(data)

  const [textContent, frags] = content.split("\n---frags---\n")

  if (frags) {
    pending[id].parts[currentChunk] = textContent
    pending[id].parts_done = true
    pending[id].parts_returned = false

    pending[id].expected_frags = pending[id].parts.join("").match(/WebRTCSrc="(.*?)"/g)?.length ?? 0

    if (frags.trim()) pending[id].frags.push(frags)
  } else if (!pending[id].parts_done) {
    pending[id].parts[currentChunk] = textContent
  } else {
    updateFrag(id, fragId, textContent)

    handleFragEnding(id, fragId, textContent)
  }

  pending[id].partsReceived++
  pending[id].type = type

  if (!isMainMessageDone(id, chunks)) return

  decodeMainMessage(id, !!frags)

  const fragsDone = pending[id].rec_frags === pending[id].expected_frags && pending[id].rec_frags !== 0
  if (frags === undefined && !pending[id].parts_done || fragsDone) delete pending[id]
}

export async function startConnection(roomId, webSocketUrl) {
  currentRoomId = roomId
  await startDatabase()
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


