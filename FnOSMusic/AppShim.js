(function () {
  var hasWebKit = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.App);
  function post(obj) { if (hasWebKit) { window.webkit.messageHandlers.App.postMessage(obj); } }

  // 与安卓版 addJavascriptInterface 的 Bridge 对齐：player.html 直接调用 window.App.xxx()
  window.App = {
    getPlaylist: function () {
      return window.__PLAYLIST__ ? JSON.stringify(window.__PLAYLIST__) : '{"tracks":[]}';
    },
    play: function (i) { post({ m: 'play', a: [i] }); },
    toggle: function () { post({ m: 'toggle' }); },
    next: function () { post({ m: 'next' }); },
    prev: function () { post({ m: 'prev' }); },
    seek: function (ms) { post({ m: 'seek', a: [ms] }); },
    setMode: function (m) { post({ m: 'setMode', a: [m] }); },
    setVolume: function (v) { post({ m: 'setVolume', a: [v] }); },
    setQueue: function (idxJson, startPos) { post({ m: 'setQueue', a: [idxJson, startPos || 0] }); },
    requestMeta: function (idx) { post({ m: 'requestMeta', a: [idx] }); },
    toggleFavorite: function (idx) { return 'false'; },
    toast: function (msg) { post({ m: 'toast', a: [msg] }); },
    // 以下接口 iOS 测试版给默认值
    getAccount: function () { return '{"saved":false}'; },
    getFavorites: function () { return '{"idxs":[]}'; },
    proxyBase: function () { return ''; },
    stat: function () { return '{}'; },
    previewOrigin: function (raw) { return raw; },
    login: function (o, u, p, r) { post({ m: 'login' }); },
    syncNow: function () { post({ m: 'syncNow' }); },
    logout: function () { post({ m: 'logout' }); },
    syncFrom: function (u) { post({ m: 'syncFrom', a: [u] }); }
  };
})();
