// ═══════════════════════════════════════════════════════════════
//  Code.gs — สำหรับ Google Apps Script (Helper System สสอ.เขาค้อ)
//  วางโค้ดนี้ทั้งหมดใน Code.gs ของ GAS Project
// ═══════════════════════════════════════════════════════════════

// ── CONFIG ──────────────────────────────────────────────────────
var SHEET_ID    = '';        // ← ใส่ Spreadsheet ID (จาก URL)
var SHEET_NAME  = 'Tasks';   // ← ชื่อ Sheet

// โครงสร้างโฟลเดอร์ใน Drive:
// 📁 HelperSystem_Attachments/
//    📁 Active/        ← งานที่กำลังดำเนินการ
//    📁 Completed/     ← งานที่เสร็จแล้ว  ✓
//    📁 Deleted/       ← งานที่ถูกลบ      🗑
var ROOT_FOLDER      = 'HelperSystem_Attachments';
var FOLDER_ACTIVE    = 'Active';
var FOLDER_COMPLETED = 'Completed';
var FOLDER_DELETED   = 'Deleted';

// ── WEB APP ENTRY POINT ─────────────────────────────────────────
function doGet(e) {
  return HtmlService.createHtmlOutputFromFile('index')
    .setTitle('Helper System — สสอ.เขาค้อ')
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}

// ── GET TASKS ───────────────────────────────────────────────────
function getTasks() {
  var sheet = getSheet();
  var rows  = sheet.getDataRange().getValues();
  if (rows.length <= 1) return [];
  var headers = rows[0];
  return rows.slice(1).map(function(row) {
    var obj = {};
    headers.forEach(function(h, i) { obj[h] = row[i] || ''; });
    if (typeof obj.imageUrls === 'string' && obj.imageUrls) {
      obj.imageUrls = obj.imageUrls.split(',').map(function(u){ return u.trim(); }).filter(Boolean);
    } else {
      obj.imageUrls = [];
    }
    return obj;
  });
}

// ── SAVE OR UPDATE TASK ─────────────────────────────────────────
function saveOrUpdateTask(taskData) {
  // อัปโหลดไฟล์ใหม่ (base64) → Drive/Active/[taskId]/
  taskData.imageUrls = uploadFilesToDrive(
    taskData.imageUrls || [],
    taskData.fileNames || [],
    taskData.id,
    FOLDER_ACTIVE
  );
  delete taskData.fileNames;

  var sheet   = getSheet();
  var headers = ensureHeaders(sheet);

  var saveData       = JSON.parse(JSON.stringify(taskData));
  saveData.imageUrls = Array.isArray(saveData.imageUrls)
    ? saveData.imageUrls.join(',')
    : (saveData.imageUrls || '');

  var rows     = sheet.getDataRange().getValues();
  var idIdx    = headers.indexOf('id');
  var foundRow = -1;
  for (var i = 1; i < rows.length; i++) {
    if (String(rows[i][idIdx]) === String(taskData.id)) { foundRow = i + 1; break; }
  }

  var rowValues = headers.map(function(h) {
    return saveData[h] !== undefined ? saveData[h] : '';
  });

  if (foundRow > 0) {
    sheet.getRange(foundRow, 1, 1, headers.length).setValues([rowValues]);
  } else {
    sheet.appendRow(rowValues);
  }

  return getTasks();
}

// ── DELETE TASK → ย้ายไฟล์ไป Deleted/ ─────────────────────────
function deleteTask(id) {
  var sheet   = getSheet();
  var rows    = sheet.getDataRange().getValues();
  var headers = rows[0];
  var idIdx   = headers.indexOf('id');

  for (var i = rows.length - 1; i >= 1; i--) {
    if (String(rows[i][idIdx]) === String(id)) {

      // ดึง imageUrls ของ task นี้แล้วย้ายไฟล์ไป Deleted/
      var urlsIdx  = headers.indexOf('imageUrls');
      var urlsRaw  = urlsIdx >= 0 ? String(rows[i][urlsIdx] || '') : '';
      var fileUrls = urlsRaw ? urlsRaw.split(',').map(function(u){ return u.trim(); }).filter(Boolean) : [];
      if (fileUrls.length > 0) {
        moveTaskFiles(id, fileUrls, FOLDER_DELETED);
      }

      sheet.deleteRow(i + 1);
      break;
    }
  }
  return getTasks();
}

// ── UPDATE STATUS → เมื่อเสร็จ ย้ายไฟล์ไป Completed/ ──────────
function updateTaskStatus(id) {
  var sheet   = getSheet();
  var rows    = sheet.getDataRange().getValues();
  var headers = rows[0];
  var idIdx     = headers.indexOf('id');
  var statusIdx = headers.indexOf('status');
  var urlsIdx   = headers.indexOf('imageUrls');

  for (var i = 1; i < rows.length; i++) {
    if (String(rows[i][idIdx]) === String(id)) {
      var cur    = rows[i][statusIdx];
      var newSt  = cur === 'active' ? 'completed' : 'active';

      // ย้ายไฟล์ตาม status ใหม่
      var urlsRaw  = urlsIdx >= 0 ? String(rows[i][urlsIdx] || '') : '';
      var fileUrls = urlsRaw ? urlsRaw.split(',').map(function(u){ return u.trim(); }).filter(Boolean) : [];
      if (fileUrls.length > 0) {
        var targetFolder = newSt === 'completed' ? FOLDER_COMPLETED : FOLDER_ACTIVE;
        var newUrls = moveTaskFiles(id, fileUrls, targetFolder);
        if (urlsIdx >= 0) {
          sheet.getRange(i + 1, urlsIdx + 1).setValue(newUrls.join(','));
        }
      }

      sheet.getRange(i + 1, statusIdx + 1).setValue(newSt);
      break;
    }
  }
  return getTasks();
}

// ── CLAUDE AI API ────────────────────────────────────────────────
function callClaudeAPI(systemPrompt, messages) {
  var apiKey = PropertiesService.getScriptProperties().getProperty('CLAUDE_API_KEY');
  if (!apiKey) throw new Error('ไม่พบ CLAUDE_API_KEY ใน Script Properties');

  var response = UrlFetchApp.fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json'
    },
    payload: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 1024,
      system: systemPrompt,
      messages: messages
    }),
    muteHttpExceptions: true
  });

  var data = JSON.parse(response.getContentText());
  if (data.error) throw new Error(data.error.message);
  return data.content && data.content[0] ? data.content[0].text : '';
}

// ══════════════════════════════════════════════════════════════════
//  DRIVE HELPERS
// ══════════════════════════════════════════════════════════════════

/**
 * อัปโหลดไฟล์ใหม่ (base64) ขึ้น Drive/[destFolderName]/[taskId]/
 * URL เดิม (Drive URL / GDOC) ไม่แตะ
 */
function uploadFilesToDrive(imageUrls, fileNames, taskId, destFolderName) {
  if (!imageUrls || imageUrls.length === 0) return [];

  var root      = getOrCreateFolder(ROOT_FOLDER);
  var destParent = getOrCreateFolder(destFolderName, root);
  var taskFolder = getOrCreateFolder(taskId || 'misc', destParent);

  var result = [];
  imageUrls.forEach(function(url, idx) {
    url = (url || '').trim();
    if (!url) return;

    // URL เดิม → ไม่อัปโหลดซ้ำ
    if (url.indexOf('data:') !== 0) { result.push(url); return; }

    try {
      var matches = url.match(/^data:([^;]+);base64,(.+)$/);
      if (!matches) { result.push(url); return; }

      var mimeType = matches[1];
      var blob     = Utilities.newBlob(Utilities.base64Decode(matches[2]), mimeType);
      var ext      = mimeType.split('/')[1] || 'bin';
      var fileName = (fileNames && fileNames[idx] && fileNames[idx] !== '')
        ? fileNames[idx]
        : ('file_' + taskId + '_' + (idx + 1) + '.' + ext);
      blob.setName(fileName);

      var file = taskFolder.createFile(blob);
      file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);

      var fileId = file.getId();
      if (mimeType.indexOf('image/') === 0) {
        result.push('https://drive.google.com/thumbnail?id=' + fileId + '&sz=w800');
      } else {
        result.push('GDOC|' + fileId + '|' + fileName);
      }
    } catch (e) {
      Logger.log('Upload error idx=' + idx + ': ' + e.message);
      result.push(url);
    }
  });

  return result;
}

/**
 * ย้ายโฟลเดอร์ของ task (และอัปเดต URL) ไปยังปลายทาง
 * Drive → จัดการโฟลเดอร์โดยตรง (ไม่ copy ไฟล์ให้สิ้นเปลือง quota)
 * คืน array ของ URL ที่อัปเดตแล้ว
 */
function moveTaskFiles(taskId, fileUrls, destFolderName) {
  try {
    var root       = getOrCreateFolder(ROOT_FOLDER);
    var destParent = getOrCreateFolder(destFolderName, root);

    // หาโฟลเดอร์ของ taskId จากทุก subfolder ใน root
    var subFolders   = [FOLDER_ACTIVE, FOLDER_COMPLETED, FOLDER_DELETED];
    var sourceFolder = null;

    for (var s = 0; s < subFolders.length; s++) {
      var parentIter = root.getFoldersByName(subFolders[s]);
      if (!parentIter.hasNext()) continue;
      var parent = parentIter.next();
      var taskIter = parent.getFoldersByName(taskId);
      if (taskIter.hasNext()) {
        sourceFolder = taskIter.next();
        break;
      }
    }

    if (!sourceFolder) {
      // ไม่เจอโฟลเดอร์ — ไม่ต้องทำอะไร คืน URL เดิม
      return fileUrls;
    }

    // ย้ายโฟลเดอร์ไปยัง destParent
    destParent.addFolder(sourceFolder);
    // ลบออกจาก parent เดิม
    var oldParent = sourceFolder.getParents();
    while (oldParent.hasNext()) {
      var p = oldParent.next();
      if (p.getId() !== destParent.getId()) {
        p.removeFolder(sourceFolder);
      }
    }

    Logger.log('ย้ายโฟลเดอร์ task ' + taskId + ' → ' + destFolderName);

    // URL ของไฟล์ใน Drive ไม่เปลี่ยน (fileId เหมือนเดิม) คืนเหมือนเดิม
    return fileUrls;

  } catch (e) {
    Logger.log('moveTaskFiles error: ' + e.message);
    return fileUrls;
  }
}

// ── SHEET HELPERS ─────────────────────────────────────────────────
function getSheet() {
  var ss = SHEET_ID
    ? SpreadsheetApp.openById(SHEET_ID)
    : SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
    sheet.appendRow(['id','workGroup','docNo','title','dueDate','startDate',
                     'priority','taskStatus','meetingLink','fileLink',
                     'imageUrls','checklist','details','space','status']);
  }
  return sheet;
}

function ensureHeaders(sheet) {
  var headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var allKeys = ['id','workGroup','docNo','title','dueDate','startDate','priority',
                 'taskStatus','meetingLink','fileLink','imageUrls','checklist',
                 'details','space','status'];
  allKeys.forEach(function(k) {
    if (headers.indexOf(k) === -1) {
      headers.push(k);
      sheet.getRange(1, headers.length).setValue(k);
    }
  });
  return headers;
}

function getOrCreateFolder(name, parent) {
  var iter = parent
    ? parent.getFoldersByName(name)
    : DriveApp.getFoldersByName(name);
  if (iter.hasNext()) return iter.next();
  return parent ? parent.createFolder(name) : DriveApp.createFolder(name);
}
