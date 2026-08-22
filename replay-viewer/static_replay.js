// Babel static replay shell: fetches the replay named by ?replay=<url>,
// hands the bytes to the wasm module (which re-derives the state timeline
// with the same Nim sim the game server runs), then drives the shared
// renderer with the resulting payload.
//
// The shell is the only thing on screen until the replay is in, so it has to
// be honest about waiting: the caption names what it is doing, a stalled
// fetch gives up after FETCH_TIMEOUT_MS instead of sitting on "LOADING"
// forever, and every failure offers a Retry that refetches without a page
// reload (the wasm module, once compiled, is reused).
(function () {
  "use strict";

  var FETCH_TIMEOUT_MS = 20000;
  var modulePromise = null;
  var attempt = 0;

  function caption(text) {
    var loading = document.getElementById("loading");
    if (!loading) return;
    loading.style.display = "";
    loading.textContent = text;
    var retry = document.getElementById("loading-retry");
    if (retry) retry.remove();
  }

  function fail(message) {
    var loading = document.getElementById("loading");
    if (loading) {
      loading.style.display = "";
      loading.textContent = "Replay failed: " + message + " ";
      var retry = document.createElement("button");
      retry.id = "loading-retry";
      retry.type = "button";
      retry.textContent = "Retry";
      retry.onclick = function () { load(); };
      loading.appendChild(retry);
    }
    document.documentElement.setAttribute("data-replay-error", message);
  }

  function readString(module, ptr, len) {
    if (!ptr || !len) return "";
    return new TextDecoder().decode(
      module.HEAPU8.subarray(ptr, ptr + len)
    );
  }

  function fetchReplay(url) {
    // AbortController bounds the wait; a fetch that never answers (a dead
    // CDN edge, a proxy holding the socket) is otherwise indistinguishable
    // from a slow one, and the caption would say LOADING until the tab died.
    var controller = typeof AbortController === "function" ?
      new AbortController() : null;
    var timer = window.setTimeout(function () {
      if (controller) controller.abort();
    }, FETCH_TIMEOUT_MS);
    return fetch(url, controller ? { signal: controller.signal } : {})
      .then(function (response) {
        if (!response.ok) throw new Error("replay fetch " + response.status);
        return response.arrayBuffer();
      })
      .catch(function (error) {
        if (error && error.name === "AbortError") {
          throw new Error("replay fetch timed out after " +
            Math.round(FETCH_TIMEOUT_MS / 1000) + "s");
        }
        throw error;
      })
      .finally(function () { window.clearTimeout(timer); });
  }

  function start(module, bytes) {
    var ptr = module._malloc(bytes.length);
    module.HEAPU8.set(bytes, ptr);
    var ok = module._bab_load_replay(ptr, bytes.length);
    module._free(ptr);
    if (!ok) {
      fail(readString(module, module._bab_error_ptr(),
        module._bab_error_len()) || "wasm rejected the replay");
      return;
    }
    var payload = JSON.parse(
      readString(module, module._bab_payload_ptr(),
        module._bab_payload_len())
    );
    var loading = document.getElementById("loading");
    if (loading) loading.style.display = "none";
    document.documentElement.removeAttribute("data-replay-error");
    BabelRenderer.attachReplay({
      canvas: document.getElementById("table"),
      feed: document.getElementById("feed"),
      scrub: document.getElementById("scrub"),
      playButton: document.getElementById("play"),
      label: document.getElementById("pos"),
      clock: document.getElementById("clock"),
      scorebug: document.getElementById("scorebug"),
      endscreen: document.getElementById("endscreen"),
      assetBase: "./assets",
      payload: payload
    });
  }

  function load() {
    var replayUrl = new URLSearchParams(location.search).get("replay");
    if (!replayUrl) {
      fail("missing required ?replay= URL");
      return;
    }
    attempt += 1;
    document.documentElement.removeAttribute("data-replay-error");
    caption(attempt > 1 ? "RETRYING REPLAY… (attempt " + attempt + ")" :
      "LOADING REPLAY…");
    if (!modulePromise) {
      modulePromise = BabelReplayModule().catch(function (error) {
        modulePromise = null;   // a failed compile is retried from scratch
        throw error;
      });
    }
    Promise.all([fetchReplay(replayUrl), modulePromise])
      .then(function (results) {
        start(results[1], new Uint8Array(results[0]));
      })
      .catch(function (error) {
        fail(String(error && error.message || error));
      });
  }

  window.addEventListener("load", load);
})();
