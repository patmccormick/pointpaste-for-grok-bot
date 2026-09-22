async function togglePick(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["pick-mode.js"],
    });
  } catch (e) {
    console.warn("PointPaste inject failed", e);
    // Show a badge so the click isn't silent
    try {
      await chrome.action.setBadgeText({ tabId, text: "!" });
      await chrome.action.setBadgeBackgroundColor({ tabId, color: "#b75e03" });
      setTimeout(() => chrome.action.setBadgeText({ tabId, text: "" }), 2500);
    } catch (_) {}
  }
}

chrome.action.onClicked.addListener((tab) => {
  if (tab?.id) togglePick(tab.id);
});

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "toggle-pick") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) togglePick(tab.id);
});
