// เพิ่มใน Code.gs ของ Google Apps Script
// เก็บ API Key ใน: File > Project Properties > Script Properties
// Key: CLAUDE_API_KEY  Value: sk-ant-api03-...

function callClaudeAPI(systemPrompt, messages) {
  var apiKey = PropertiesService.getScriptProperties().getProperty('CLAUDE_API_KEY');
  if (!apiKey) throw new Error('ไม่พบ CLAUDE_API_KEY ใน Script Properties');

  var payload = {
    model: 'claude-haiku-4-5-20251001',
    max_tokens: 1024,
    system: systemPrompt,
    messages: messages
  };

  var options = {
    method: 'POST',
    headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json'
    },
    payload: JSON.stringify(payload),
    muteHttpExceptions: true
  };

  var response = UrlFetchApp.fetch('https://api.anthropic.com/v1/messages', options);
  var data = JSON.parse(response.getContentText());

  if (data.error) throw new Error(data.error.message);
  return data.content && data.content[0] ? data.content[0].text : '';
}
