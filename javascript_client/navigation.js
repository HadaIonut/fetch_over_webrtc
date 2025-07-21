import { listenForFrag, readFrag } from "./database.js"
import { fetchOverWebRTC } from "./main.js"

function onFragHanlder(fragId) {
  readFrag(fragId).onsuccess = (event) => {
    const content = event.target.result.content

    const elem = document.querySelector(`[WebRTCSrc="__url_replace_${fragId}__"]`)
    if (!elem || elem.nodeName === "SCRIPT") return
    if (elem.nodeName === "LINK") {
      elem.href = content
    } else if (elem.nodeName === "SOURCE") {
      elem.srcset = content
    } else {
      elem.src = content
    }
  }
}

function handleStyles(doc) {
  const styles = doc.head.querySelectorAll('link[rel="stylesheet"], style')
  for (const style of styles) {
    document.head.appendChild(style.cloneNode(true))
  }
}

function parseScriptSrc(fragId, newScript) {
  return new Promise(res => {
    let intervalId = setInterval(() => {
      readFrag(fragId).onsuccess = (event) => {
        const result = event.target.result
        if (!result) return
        const content = event.target.result.content
        newScript.textContent = atob(content.split(",")[1])
        res()
        clearInterval(intervalId)
      }
    })
  })
}

async function handleScripts(scripts) {
  for (const oldScript of scripts) {
    const newScript = document.createElement('script');

    let skip = false
    for (const attr of oldScript.attributes) {
      if (attr.name === "webrtcsrc") {
        const fragId = attr.value.slice(14, 24)
        await parseScriptSrc(fragId, newScript)
        skip = true
      } else {
        newScript.setAttribute(attr.name, attr.value);
      }
    }
    if (!oldScript.src && !skip) {
      newScript.textContent = oldScript.textContent;
    }
    document.body.appendChild(newScript);
  }
}

export async function navigateOverWebRTC(url, params = {}, useURL = false) {
  const result = await fetchOverWebRTC(url, params)
  const html = result.body
  const parser = new DOMParser()

  const doc = parser.parseFromString(html, "text/html")

  handleStyles(doc)

  const scripts = doc.querySelectorAll('script');

  document.body.replaceWith(doc.body)

  await handleScripts(scripts)

  if (useURL) {
    const path = url.split("/")[3]

    history.pushState({}, '', `/${currentRoomId}/${path}`)
  }
  listenForFrag(onFragHanlder)
}
