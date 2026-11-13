// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === "ping") {
    const tabId = sender.tab ? sender.tab.id : undefined;
    chrome.action.setBadgeText({ text: "ok", tabId });
    chrome.storage.local.set({ lastPing: message.url });
    sendResponse({ type: "pong", tabId });
  }
});
