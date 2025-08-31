import { startConnection, overrideFetch } from "./main.js"
import { navigateOverWebRTC } from "./navigation.js"

const WEB_SOCKET_URL = "ws://127.0.0.1:3000/ws"
overrideFetch()

document.querySelector("#connectRoom").addEventListener("click", async () => {
  const roomId = document.querySelector("#roomId").value

  await startConnection(roomId, WEB_SOCKET_URL)

  setInterval(async () => console.log("get echo fetch overriden", await fetch("http://localhost:8080/ping")), 10000)

  console.log("post echo fetch overriden ", await fetch("http://localhost:8080/echo", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: {
      a: "a",
      b: "b"
    }
  }))

  console.log("html", await navigateOverWebRTC("http://brave.com", {}))
})

document.querySelector("#fileUpload").addEventListener("change", async (event) => {
  const files = [...event.target.files]

  console.log("file upload", await fetch("http://localhost:8080/upload", {
    method: "POST",
    headers: { "Content-Type": "multipart/form-data" },
    body: {
      textContent: {
        description: "fjsklafjdslka",
      },
      files: files
    }
  }))
})

