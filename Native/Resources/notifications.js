(() => {
  'use strict';
  if (window !== window.top || location.origin !== 'https://chat.google.com') return;
  const handler = window.webkit?.messageHandlers?.nookNativeNotifications;
  if (!handler) return;
  let permission = 'default';
  let serial = 0;
  const page = window.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
  const instances = new Map();
  const pending = new Map();
  const bound = (value, size) => String(value ?? '').slice(0, size);
  const post = data => handler.postMessage(data);
  class NativeNotification extends EventTarget {
    static get permission() { return permission; }
    static get maxActions() { return 0; }
    static requestPermission(callback) {
      if (pending.size >= 128) return Promise.resolve(permission);
      const request = `${page}-permission-${++serial}`;
      return new Promise(resolve => {
        pending.set(request, value => { resolve(value); if (typeof callback === 'function') callback(value); });
        post({ type: 'permission', request });
      });
    }
    constructor(title, options = {}) {
      super();
      this.title = bound(title, 120);
      this.body = bound(options.body, 500);
      this.tag = bound(options.tag, 120);
      this.silent = Boolean(options.silent);
      this.data = options.data ?? null;
      this.onclick = this.onclose = this.onerror = this.onshow = null;
      this._id = `${page}-notification-${++serial}`;
      if (instances.size >= 128) instances.delete(instances.keys().next().value);
      instances.set(this._id, this);
      post({ type: 'show', id: this._id, title: this.title, body: this.body, tag: this.tag, silent: this.silent });
    }
    close() { if (this._closed) return; this._closed = true; post({ type: 'close', id: this._id }); instances.delete(this._id); this._emit('close'); }
    _emit(type) { const event = new Event(type); this.dispatchEvent(event); if (typeof this[`on${type}`] === 'function') this[`on${type}`].call(this, event); }
  }
  Object.defineProperty(window, 'Notification', { configurable: true, writable: true, value: NativeNotification });
  Object.defineProperty(window, '__nookNotificationReceive', { configurable: true, value: message => {
    if (['default', 'denied', 'granted'].includes(message.permission)) permission = message.permission;
    if (message.request && pending.has(message.request)) { const resolve = pending.get(message.request); pending.delete(message.request); resolve(permission); }
    const instance = instances.get(message.id);
    if (instance && ['show', 'click', 'error', 'close'].includes(message.event)) {
      instance._emit(message.event);
      if (message.event === 'close' || message.event === 'error') instances.delete(message.id);
    }
  } });
  post({ type: 'status' });
})();
