import { startConnection, sendMessage, overrideFetch } from "./main.js"

const WEB_SOCKET_URL = "ws://127.0.0.1:3000/ws"
overrideFetch()


document.querySelector("#connectRoom").addEventListener("click", async () => {
  const roomId = document.querySelector("#roomId").value

  await startConnection(roomId, WEB_SOCKET_URL)

  console.log("get echo fetch overriden", await fetch("http://localhost:8080/ping"))

  console.log("post echo fetch overriden ", await fetch("http://localhost:8080/echo", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: {
      a: "a",
      b: "b"
    }
  }))

  console.log("html", await fetch("http://localhost:8080/"))

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



