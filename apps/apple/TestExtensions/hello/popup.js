// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Exercises chrome.tabs (and so the app's tab/window adapters).
chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
  const out = document.getElementById("out");
  if (chrome.runtime.lastError) {
    out.textContent = "error: " + chrome.runtime.lastError.message;
  } else {
    out.textContent = tabs.length ? "Active tab: " + tabs[0].title + " (" + tabs.length + ")" : "no active tab";
  }
});
