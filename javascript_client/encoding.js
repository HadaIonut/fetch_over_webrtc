import { BitReader } from "./bitReader.js";
import { BitWriter } from "./bitWriter.js";

const CHUNK_SIZE = 12500 // bytes
const TYPE_TO_ID_MAP = {
  "GET": 0,
  "POST": 1,
  "PUT": 2,
  "DELETE": 3
}

const ID_TO_TYPE_MAP = {
  0: "GET",
  1: "POST",
  2: "PUT",
  3: "DELETE"
}

function chunkBuffer(buffer, chunkSize) {
  /** @type(UInt8Array[]) */
  const chunks = [];
  const totalBytes = buffer.byteLength;

  for (let offset = 0; offset < totalBytes; offset += chunkSize) {
    const chunk = buffer.slice(offset, Math.min(offset + chunkSize, totalBytes));
    chunks.push(chunk);
  }

  return chunks;
}

function uuidToBytes(uuid) {
  console.log(uuid)
  const hex = uuid.replace(/-/g, '');
  if (hex.length !== 32) throw new Error("Invalid UUID format");
  console.log(hex)

  const bytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  console.log(bytes)
  return bytes;
}
function bytesToUuid(bitReader) {
  const uuidBytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    uuidBytes[i] = bitReader.readBits(8);
  }

  const hex = Array.from(uuidBytes, byte => byte.toString(16).padStart(2, '0')).join('');

  // Insert dashes at the standard UUID positions: 8-4-4-4-12
  return (
    hex.slice(0, 8) + '-' +
    hex.slice(8, 12) + '-' +
    hex.slice(12, 16) + '-' +
    hex.slice(16, 20) + '-' +
    hex.slice(20)
  );
}


export function encodeMessage(message, requestType, id = crypto.randomUUID()) {
  const encoder = new TextEncoder()
  const payload = encoder.encode(message)

  const chunks = chunkBuffer(payload, CHUNK_SIZE)

  return chunks.reduce((acc, cur, index) => {
    const writer = new BitWriter((4 + 16 + 16 + 4) / 8)

    console.log("chunks", chunks.length)
    writer.writeBits(1, 4)
    writer.writeBits(chunks.length, 16)
    writer.writeBits(index, 16)
    writer.writeBits(TYPE_TO_ID_MAP[requestType], 4)

    const writerResult = writer.getBuffer()
    const uuidBytes = uuidToBytes(id)

    const headerLen = writerResult.byteLength + uuidBytes.byteLength

    const result = new Uint8Array(headerLen + cur.byteLength)
    result.set(new Uint8Array(writerResult), 0)
    result.set(new Uint8Array(uuidBytes), writerResult.byteLength)
    result.set(cur, headerLen)

    return [
      ...acc,
      result
    ]
  }, [])
}


export function decodeMessage(message) {
  const reader = new BitReader(message)

  const version = reader.readBits(4)
  if (version !== 1) throw new Error("Unknown version received")

  const chunks = reader.readBits(16)
  const currentChunk = reader.readBits(16)
  const type = ID_TO_TYPE_MAP[reader.readBits(4)]

  const id = bytesToUuid(reader)
  const contentBytes = reader.readRemainingBits()
  const decoder = new TextDecoder("utf-8")
  const content = decoder.decode(contentBytes)
  console.log(contentBytes)


  return { chunks, currentChunk, type, id, content }
}

encodeMessage("ligma ballz", "GET").forEach(v => {
  console.log("Bytes:", [...v].map(b => b.toString(16).padStart(2, '0')).join(' '));
  console.log(decodeMessage(v))
})
