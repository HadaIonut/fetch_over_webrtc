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

export async function startDataChannel(roomId) {
  peerConnection = new RTCPeerConnection()
  const dataChannel = peerConnection.createDataChannel("ligma")
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
})

await new Promise((res) => {
  socket.addEventListener("open", _ => res())
})

const roomId = "D86165A3-33BC-41DF-A611-EA056315A8B8"

console.log(await sendJoinRoomMessage(roomId))
const datachannel = await startDataChannel(roomId)

setInterval(() => datachannel.send("ping"), 1000)

datachannel.addEventListener("message", (event) => console.log("message: " + event.data))
