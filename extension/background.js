const BLOCKED = /^(chrome|brave|edge|about|chrome-extension|devtools|view-source|chrome-search|chrome-native):/i;
const STORE = /chromewebstore\.google\.com|chrome\.google\.com\/webstore/i;

async function flashError(tabId, message) {
  try {
    await chrome.action.setBadgeText({ tabId, text: "!" });
    await chrome.action.setBadgeBackgroundColor({ tabId, color: "#c62828" });
    await chrome.action.setTitle({
      tabId,
      title: message || "PointTalk failed — open a normal website and try again",
    });
    setTimeout(async () => {
      try {
        await chrome.action.setBadgeText({ tabId, text: "" });
        await chrome.action.setTitle({
          tabId,
          title: "PointTalk → Grok Bot (Alt+Shift+G)",
        });
      } catch (_) {}
    }, 4000);
  } catch (_) {}
}

async function ensureHostAccess(url) {
  if (!url || !/^https?:/i.test(url)) return false;
  try {
    let origin;
    try {
      origin = new URL(url).origin + "/*";
    } catch (_) {
      return false;
    }
    const have = await chrome.permissions.contains({ origins: [origin] });
    if (have) return true;
    // ActiveTab usually covers the click; if scripting still fails we request this.
    return await chrome.permissions.request({ origins: [origin] });
  } catch (_) {
    return false;
  }
}

async function inject(tabId) {
  await chrome.scripting.executeScript({
    target: { tabId },
    files: ["pick-mode.js"],
    injectImmediately: true,
  });
}

async function togglePick(tab) {
  if (!tab?.id) return;
  const tabId = tab.id;
  const url = tab.url || "";

  if (!url || BLOCKED.test(url) || STORE.test(url) || url.startsWith("file:")) {
    await flashError(
      tabId,
      "PointTalk can’t run on this tab. Open a normal http:// or https:// page, then click again."
    );
    return;
  }

  try {
    await inject(tabId);
    await chrome.action.setBadgeText({ tabId, text: "" });
    return;
  } catch (first) {
    console.warn("PointTalk inject attempt 1", first);
  }

  // Permission / activeTab miss — ask for this origin and retry once
  const granted = await ensureHostAccess(url);
  if (granted) {
    try {
      await inject(tabId);
      await chrome.action.setBadgeText({ tabId, text: "" });
      return;
    } catch (second) {
      console.warn("PointTalk inject attempt 2", second);
      await flashError(
        tabId,
        "PointTalk still can’t inject here (" +
          (second && second.message ? second.message : "error") +
          "). Reload the extension on brave://extensions, then retry."
      );
      return;
    }
  }

  await flashError(
    tabId,
    "PointTalk needs permission for this site. Click Allow if Brave prompts, or reload the extension."
  );
}

chrome.action.onClicked.addListener((tab) => {
  togglePick(tab);
});

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "toggle-pick") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) togglePick(tab);
});
