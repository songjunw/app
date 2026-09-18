(function () {
  var hasWebKit = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.App);
  function post(obj) { if (hasWebKit) { window.webkit.messageHandlers.App.postMessage(obj); } }

  // 初始状态由原生在 atDocumentStart 注入：
  //   window.__PLAYLIST__ / __ACCOUNT__ / __FAVS__ / __favIdxs / __STAT__
  if (!window.__PLAYLIST__) window.__PLAYLIST__ = { "tracks": [] };
  if (!window.__ACCOUNT__) window.__ACCOUNT__ = { "saved": false };
  if (!window.__FAVS__) window.__FAVS__ = { "idxs": [] };
  if (!window.__favIdxs) window.__favIdxs = [];
  if (!window.__STAT__) window.__STAT__ = {};
  if (!window.__SYNCTRACE__) window.__SYNCTRACE__ = { crashed: false, trace: '' };

  window.App = {
    getPlaylist: function () { return JSON.stringify(window.__PLAYLIST__); },
    getAccount: function () { return JSON.stringify(window.__ACCOUNT__); },
    getFavorites: function () { return JSON.stringify({ idxs: window.__favIdxs }); },
    stat: function () { return JSON.stringify(window.__STAT__); },
    getSyncTrace: function () { return JSON.stringify(window.__SYNCTRACE__ || { crashed: false, trace: '' }); },

    play: function (i) { post({ m: 'play', a: [i] }); },
    toggle: function () { post({ m: 'toggle' }); },
    next: function () { post({ m: 'next' }); },
    prev: function () { post({ m: 'prev' }); },
    seek: function (ms) { post({ m: 'seek', a: [ms] }); },
    setMode: function (m) { post({ m: 'setMode', a: [m] }); },
    setVolume: function (v) { post({ m: 'setVolume', a: [v] }); },
    setQueue: function (idxJson, startPos) { post({ m: 'setQueue', a: [idxJson, startPos || 0] }); },
    requestMeta: function (idx) { post({ m: 'requestMeta', a: [idx] }); },
    toast: function (msg) { post({ m: 'toast', a: [msg] }); },

    // 收藏本地乐观更新（立即返回新状态），同时通知原生持久化
    toggleFavorite: function (idx) {
      var s = window.__favIdxs;
      var i = s.indexOf(idx);
      var on;
      if (i >= 0) { s.splice(i, 1); on = false; }
      else { s.push(idx); on = true; }
      post({ m: 'toggleFavorite', a: [idx, on] });
      return on ? 'true' : 'false';
    },

    // 纯字符串换算（与安卓 SyncManager.normOrigin 一致），无需原生往返
    previewOrigin: function (raw) {
      var s = (raw || '').trim();
      if (!s) return raw;
      if (!/^https?:\/\//i.test(s)) s = 'https://' + s;
      while (s.charAt(s.length - 1) === '/') s = s.slice(0, -1);
      var m = s.match(/^https?:\/\/([^\/]+)(?:\/?(.*))?$/);
      if (!m) return raw;
      var host = m[1], path = m[2] || '';
      if (host.indexOf(':') >= 0) return s;
      if (!path || path.indexOf('/') >= 0 || path.indexOf('?') >= 0) return s;
      return 'https://' + path + '.' + host;
    },

    login: function (o, u, p, r) { post({ m: 'login', a: [o, u, p, r] }); },
    syncNow: function () { post({ m: 'syncNow' }); },
    logout: function () { post({ m: 'logout' }); },
    syncFrom: function (u) { post({ m: 'syncFrom', a: [u] }); }
  };
})();
