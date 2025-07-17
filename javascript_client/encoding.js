import { BitReader } from "./bitReader.js";
import { BitWriter } from "./bitWriter.js";
/** @typedef {import('./types.d.ts').Header} Header */
/** @typedef {import('./types.d.ts').Body} Body */
/** @typedef {import('./types.d.ts').MultipartBody} MultipartBody*/

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

const TEXT_CONTENT_TYPES = ["text/plain", "text/html", "text/css", "text/javascript", "text/csv"]

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
  const hex = uuid.replace(/-/g, '');
  if (hex.length !== 32) throw new Error("Invalid UUID format");

  const bytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
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

function encodeRequestHeaders(requestHeaders) {
  const msg = Object.keys(requestHeaders).reduce((acc, cur) => {
    acc += `${cur}=${requestHeaders[cur]},`
  }, "")

  return msg.charAt(msg.length - 1) === "," ? msg.slice(0, -1) : msg
}

async function blobToBase64(blob) {
  const arrayBuffer = await blob.arrayBuffer();
  const bytes = new Uint8Array(arrayBuffer);

  const binary = bytes.reduce((acc, byte) => acc + String.fromCharCode(byte), '');
  return btoa(binary);
}

function base64ToFile(base64, filename, mimeType) {
  const arr = base64.split(',');
  const bstr = atob(arr.length > 1 ? arr[1] : arr[0])
  let n = bstr.length;
  const u8arr = new Uint8Array(n);

  while (n--) {
    u8arr[n] = bstr.charCodeAt(n);
  }

  return new File([u8arr], filename, { type: mimeType });
}

/**
  * @param {Header} header
  * @returns {[string, string]}
  */
function encodeHeader(header) {
  let encodedHeader = ""
  encodedHeader += `Route: ${header.route}\n`
  encodedHeader += `RequestHeaders: ${encodeRequestHeaders(header.requestHeaders ?? {})}\n`
  encodedHeader += `ContentType: ${header.contentType ?? ''}`
  encodedHeader += '\r\n'

  return [encodedHeader, header.requestType]
}

/**
 * @param {MultipartBody} body 
 * @returns {Promise<string>}
 */
async function encodeMulitpartBody(body) {
  const textPart = `----\n${JSON.stringify(body.textContent)}\n----\n`

  let filesPart = ""

  for (const file of body.files) {
    filesPart += `----\nFileName:${file.name}\nFileType:${file.type ?? 'text'}\n${await blobToBase64(file)}`
  }
  filesPart += '\n----'

  return `${textPart}${filesPart}`
}

/** 
 * @param {Body} body 
 * @param {string} contentType 
 * @returns {Promise<string>}
 */
async function encodeBody(body, contentType) {
  if (contentType.startsWith("text/")) return body
  if (contentType === "multipart/form-data") return await encodeMulitpartBody(body)
  return JSON.stringify(body)
}



/**
 * @param {string} requestHeaders 
 * @returns {Record<string, string>}
 */
function decodeRequestHeaders(requestHeaders) {
  if (requestHeaders === '' || !requestHeaders) return {}
  const parts = requestHeaders.split(",")

  return parts.reduce((acc, cur) => {
    const [key, value] = cur.split("=")

    return {
      ...acc,
      [key]: value
    }
  }, {})
}

/**
 * @param {string} text
 * @returns {Header}
 */
function decodeTextHeader(text) {
  let [route, requestHeaders, contentType] = text.split("\n")
  route = route.split("Route: ")[1]
  requestHeaders = requestHeaders?.split("RequestHeaders: ")[1]
  requestHeaders = decodeRequestHeaders(requestHeaders)
  contentType = contentType?.split("ContentType: ")?.[1]

  return {
    route, requestHeaders, contentType
  }
}

function decodeMultipartBody(body) {
  const parts = body.split("----\n").filter(v => v !== '')
  const text = parts[0]

  const files = []

  for (let i = 1; i < parts.length; i++) {
    let [fileName, fileType, fileContent] = parts[i].split("\n")
    fileName = fileName.split("FileName:")[1]
    fileType = fileType.split("FileType:")[1]

    files.push(base64ToFile(fileContent, fileName, fileType))
  }

  return {
    textContent: JSON.parse(text),
    files: files
  }
}

function decodeBody(body, contentType) {
  if (TEXT_CONTENT_TYPES.includes(contentType)) return body
  if (contentType === "application/json") return JSON.parse(body)
  if (contentType === "multipart/form-data") return decodeMultipartBody(body)

  return body
}

/**
  * @param {Header} header
  * @param {Body} body
  * @returns {Promise<[string, string]>}
  */
export async function textEncodeMessage(header, body) {
  const [encodedHeader, requestType] = encodeHeader(header)
  const encodedBody = await encodeBody(body, header.contentType ?? "text/plain")

  return [`${encodedHeader}${encodedBody}`, requestType]
}

/**
 * @returns {Uint8Array[]}
 */
export function binaryEncodeMessage(message, requestType, id = crypto.randomUUID()) {
  const encoder = new TextEncoder()
  const payload = encoder.encode(message)

  const chunks = chunkBuffer(payload, CHUNK_SIZE)

  return chunks.reduce((acc, cur, index) => {
    const writer = new BitWriter((4 + 16 + 16 + 4) / 8)

    writer.writeBits(1, 2)
    writer.writeBits(0, 2)
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

function binaryToString(reader, len) {
  const data = new Uint8Array(len)

  for (let i = 0; i < len; i++) {
    data.set([reader.readBits(8)], i)
  }

  const decoder = new TextDecoder("utf-8")
  const content = decoder.decode(data)

  return content
}

/**
 * @param {string} text - text to be decoded 
 * @returns {[Header, Body]}
 */
export function textDecodeMessage(text) {
  let [header, body] = text.split("\r\n")

  header = decodeTextHeader(header)
  body = decodeBody(body, header.contentType)

  return [header, body]
}

/**
 * @param {ArrayBuffer} message 
 */
export function binaryDecodeMessage(message) {
  const reader = new BitReader(message)

  // header 
  const version = reader.readBits(2)
  if (version !== 1) throw new Error("Unknown version received")

  const hasFrags = reader.readBits(2)

  const chunks = reader.readBits(16)
  const currentChunk = reader.readBits(16)
  const type = ID_TO_TYPE_MAP[reader.readBits(4)]
  const id = bytesToUuid(reader)

  let fragId = hasFrags ? binaryToString(reader, 10) : null

  //body
  const contentBytes = reader.readRemainingBits()

  const decoder = new TextDecoder("utf-8")
  const content = decoder.decode(contentBytes)

  return { chunks, hasFrags, currentChunk, type, id, content, fragId }
}

