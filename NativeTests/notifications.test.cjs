const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../Native/Resources/notifications.js'), 'utf8');
function page(origin = 'https://chat.google.com', main = true) {
  const messages = [];
  const window = { crypto: { randomUUID: () => 'test-page' }, webkit: { messageHandlers: { nookNativeNotifications: { postMessage: value => messages.push(value) } } } };
  window.top = main ? window : {};
  vm.runInNewContext(source, { window, location: { origin }, EventTarget, Event, Date, Math });
  return { window, messages, receive: value => window.__nookNotificationReceive(value) };
}
test('only the exact Chat HTTPS origin and main frame receive the bridge', () => {
  for (const [origin, main] of [['http://chat.google.com', true], ['https://chat.google.com.evil.test', true], ['https://chat.google.com:444', true], ['https://mail.google.com', true], ['https://chat.google.com', false]]) {
    const p = page(origin, main);
    assert.equal(p.window.Notification, undefined);
    assert.equal(p.messages.length, 0);
  }
  assert.equal(page().messages[0].type, 'status');
});
test('permission stays default until macOS replies, and denial resolves the correct request', async () => {
  const p = page();
  assert.equal(p.window.Notification.permission, 'default');
  let callback;
  const first = p.window.Notification.requestPermission(value => { callback = value; });
  const second = p.window.Notification.requestPermission();
  const requests = p.messages.filter(m => m.type === 'permission');
  assert.equal(p.window.Notification.permission, 'default');
  p.receive({ permission: 'denied', request: requests[1].request });
  assert.equal(await second, 'denied');
  assert.equal(callback, undefined);
  p.receive({ permission: 'granted', request: requests[0].request });
  assert.equal(await first, 'granted');
  assert.equal(callback, 'granted');
  p.receive({ permission: 'invented' });
  assert.equal(p.window.Notification.permission, 'granted');
});
test('payloads are bounded and unsupported native capabilities are omitted', () => {
  const p = page();
  const n = new p.window.Notification('x'.repeat(200), { body: 'y'.repeat(800), tag: 'z'.repeat(200), silent: true, icon: 'file:///private', data: { url: 'https://evil.test' } });
  const message = p.messages.at(-1);
  assert.equal(message.title.length, 120);
  assert.equal(message.body.length, 500);
  assert.equal(message.tag.length, 120);
  assert.equal(message.silent, true);
  assert.deepEqual(Object.keys(message).sort(), ['body', 'id', 'silent', 'tag', 'title', 'type']);
  assert.equal(n.data.url, 'https://evil.test');
});
test('native events reach listeners and property handlers; closed pages ignore later click', () => {
  const p = page();
  const n = new p.window.Notification('Chat');
  const id = p.messages.at(-1).id;
  let clicks = 0, shows = 0, closes = 0;
  n.addEventListener('click', () => clicks++);
  n.onclick = () => clicks++;
  n.onshow = () => shows++;
  n.onclose = () => closes++;
  p.receive({ id, event: 'show' });
  p.receive({ id, event: 'click' });
  assert.equal(shows, 1);
  assert.equal(clicks, 2);
  n.close();
  assert.equal(p.messages.at(-1).type, 'close');
  assert.equal(closes, 1);
  p.receive({ id, event: 'click' });
  assert.equal(clicks, 2);
});
test('tracking cap drops old callbacks without blocking fresh notifications', () => {
  const p = page();
  const old = new p.window.Notification('old');
  const oldID = p.messages.at(-1).id;
  let oldClicks = 0;
  old.onclick = () => oldClicks++;
  for (let i = 0; i < 128; i++) new p.window.Notification(String(i));
  p.receive({ id: oldID, event: 'click' });
  assert.equal(oldClicks, 0);
});
