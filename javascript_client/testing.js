import { startConnection, sendMessage, overrideFetch } from "./main.js"

const roomId = "B169005F-5272-4BCA-A7C4-3599B77A233D"

await startConnection(roomId)
overrideFetch()

document.querySelector("input").addEventListener("change", async (event) => {
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


console.log("get echo fetch overriden", await fetch("http://localhost:8080/ping"))

console.log("post echo fetch overriden ", await fetch("http://localhost:8080/echo", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: {
    a: "a",
    b: "b"
  }
}))
