// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Marks the page so the smoke test can see the content script ran,
// then round-trips a message through the background service worker.
document.title = "[hello] " + document.title;
document.documentElement.dataset.helloExtension = "ran";

chrome.runtime.sendMessage({ type: "ping", url: location.href }, (reply) => {
  const err = chrome.runtime.lastError;
  document.documentElement.dataset.helloBackground =
    err ? "error: " + err.message : (reply && reply.type) || "no-reply";
});
