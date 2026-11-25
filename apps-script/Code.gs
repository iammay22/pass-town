// 及格鎮數據後台：遊戲送來的事件寫進「events」分頁
// 改了這個檔案以後，要到「部署 > 管理部署作業」編輯部署、選「新版本」，網址才會更新內容。

const SHEET = 'events';
const HEAD = ['時間', '玩家', '事件', '數值', '細節', '裝置', '來源'];

function doPost(e) {
  const lock = LockService.getScriptLock();
  lock.waitLock(5000);
  try {
    const d = JSON.parse(e.postData.contents || '{}');
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    let sh = ss.getSheetByName(SHEET);
    if (!sh) { sh = ss.insertSheet(SHEET); sh.appendRow(HEAD); }
    const v = d.value === '' || d.value === undefined ? '' : (isNaN(Number(d.value)) ? String(d.value) : Number(d.value));
    sh.appendRow([new Date(), String(d.pid || '').slice(0, 20), String(d.event || '').slice(0, 20), v,
      String(d.detail || '').slice(0, 60), String(d.device || '').slice(0, 10), String(d.source || '').slice(0, 60)]);
  } finally {
    lock.releaseLock();
  }
  return ContentService.createTextOutput('ok');
}

function doGet() {
  return ContentService.createTextOutput('alive');
}
