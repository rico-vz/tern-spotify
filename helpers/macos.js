ObjC.import('Foundation');
ObjC.import('AppKit');

var BUNDLE_ID = 'com.spotify.client';
var APP_NAME = 'Spotify';

var LOOP_DELAY = 0.4;
var LEASE_TIMEOUT = 45;
var START_GRACE = 45;
var STALE_LOCK_SECS = 10;
var CMD_STALE_SECS = 15;
var CMD_YOUNG_SECS = 3;
var POS_JUMP_MS = 1500;
var BACKOFF_MS = 2000;
var LOG_MAX_BYTES = 64 * 1024;

var UTF8 = $.NSUTF8StringEncoding;

var spotifyDownUntilMs = 0;

function nowMs() { return Date.now(); }
function nowSec() { return Math.floor(Date.now() / 1000); }
function sleepSeconds(s) { delay(s); }

function fm() { return $.NSFileManager.defaultManager; }

function isNil(o) {
  if (o === null || o === undefined) return true;
  try { return typeof o.isNil === 'function' && o.isNil(); } catch (e) { return false; }
}

function exists(path) {
  try { return !!fm().fileExistsAtPath(path); } catch (e) { return false; }
}

function readFile(path) {
  try {
    var s = $.NSString.stringWithContentsOfFileEncodingError(path, UTF8, $());
    if (isNil(s)) return null;
    var v = ObjC.unwrap(s);
    return v === undefined ? null : String(v);
  } catch (e) { return null; }
}

function writeFile(path, text) {
  try {
    var js = String(text);
    var s = $.NSString.alloc.initWithUTF8String(js);
    if (isNil(s)) s = $.NSString.stringWithString(js);
    if (isNil(s)) return false;
    return !!s.writeToFileAtomicallyEncodingError(path, true, UTF8, $());
  } catch (e) { return false; }
}

function atomicWrite(path, text) {
  return writeFile(path, text);
}

function removePath(path) {
  try { fm().removeItemAtPathError(path, $()); } catch (e) { /* already gone */ }
}

function movePath(from, to) {
  try { return !!fm().moveItemAtPathToPathError(from, to, $()); } catch (e) { return false; }
}

function mkdir(path, intermediates) {
  try {
    return !!fm().createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
      path, !!intermediates, $(), $());
  } catch (e) { return false; }
}

function listDir(path) {
  var out = [];
  try {
    var a = fm().contentsOfDirectoryAtPathError(path, $());
    if (isNil(a)) return out;
    var n = Number(a.count);
    for (var i = 0; i < n; i++) {
      var v = ObjC.unwrap(a.objectAtIndex(i));
      if (v !== undefined && v !== null) out.push(String(v));
    }
  } catch (e) {}
  return out;
}

function logErr(data, msg) {
  try {
    var path = data + '/helper.log';
    try {
      var attrs = fm().attributesOfItemAtPathError(path, $());
      if (!isNil(attrs)) {
        var size = attrs.objectForKey('NSFileSize');
        if (!isNil(size) && Number(size) > LOG_MAX_BYTES) removePath(path);
      }
    } catch (e) {}
    var prev = readFile(path);
    writeFile(path, (prev === null ? '' : prev) + new Date().toISOString() + ' ' + clean(msg) + '\n');
  } catch (e) {}
}

function clean(v) {
  if (v === null || v === undefined) return '';
  return String(v).replace(/[\r\n]+/g, ' ');
}

function txt(v) {
  var s = clean(v);
  if (s === 'missing value' || s === 'null' || s === 'undefined') return '';
  return s;
}

function parseKey(text, key) {
  if (text === null) return null;
  var lines = text.split(/\r?\n/);
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf('=');
    if (idx < 0) continue;
    if (lines[i].slice(0, idx) === key) return lines[i].slice(idx + 1);
  }
  return null;
}

function spotifyRunning() {
  try {
    var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(BUNDLE_ID);
    if (isNil(apps)) return false;
    var n = Number(apps.count);
    for (var i = 0; i < n; i++) {
      var app = apps.objectAtIndex(i);
      if (isNil(app)) continue;
      if (app.terminated) continue;
      if (!app.finishedLaunching) continue;
      return true;
    }
  } catch (e) {}
  return false;
}

function markDown() {
  spotifyDownUntilMs = nowMs() + BACKOFF_MS;
}

function canReachSpotify() {
  return nowMs() >= spotifyDownUntilMs && spotifyRunning();
}

function readSpotify() {
  var sp;
  var r = {};
  try {
    sp = Application(BUNDLE_ID);
    r.status = txt(sp.playerState());
  } catch (e) {
    return null;
  }
  r.position = null;
  try { var p = Number(sp.playerPosition()); if (isFinite(p)) r.position = p; } catch (e) {}

  r.volume = null;
  try { var v = Number(sp.soundVolume()); if (isFinite(v)) r.volume = v; } catch (e) {}

  r.shuffle = null;
  try { r.shuffle = !!sp.shuffling(); } catch (e) {}
  r.repeatOn = null;
  try { r.repeatOn = !!sp.repeating(); } catch (e) {}
  r.shuffleEnabled = null;
  try { r.shuffleEnabled = !!sp.shufflingEnabled(); } catch (e) {}
  r.repeatEnabled = null;
  try { r.repeatEnabled = !!sp.repeatingEnabled(); } catch (e) {}

  r.title = ''; r.artist = ''; r.album = ''; r.trackId = ''; r.artworkUrl = '';
  r.duration = null;
  try {
    var t = sp.currentTrack;
    if (Array.isArray(t)) t = t[0];          // few bridges return a one-element list
    var id = txt(t.id());
    r.title = txt(t.name());
    r.artist = txt(t.artist());
    r.album = txt(t.album());
    r.trackId = (id && id.indexOf('spotify:') === 0) ? id : '';
    r.artworkUrl = txt(t.artworkUrl());
    var d = Number(t.duration());
    if (isFinite(d) && d > 0) r.duration = d;
  } catch (e) {
    if (!spotifyRunning()) { markDown(); return null; }
  }
  return r;
}

function normalizeStatus(s) {
  s = String(s || '').toLowerCase();
  if (s === 'playing' || s === 'paused' || s === 'stopped') return s;
  return 'stopped';
}

function premutePath(data) { return data + '/premute'; }

function setVolume(sp, target) {
  target = Math.round(target);
  if (target < 0) target = 0;
  if (target > 100) target = 100;
  var set = target;
  var special = (target === 0 || target === 40 || target === 60 ||
                 target === 80 || target === 100);
  if (!special) {
    set = target + 1;
    if (set > 100) set = 100;
  }
  sp.soundVolume = set;
}

function readPremute(data) {
  var raw = readFile(premutePath(data));
  if (raw === null) return null;
  var n = parseInt(String(raw).trim(), 10);
  return isFinite(n) ? n : null;
}

function applyMute(data, sp, on) {
  var pre = premutePath(data);
  if (on) {
    if (!exists(pre)) {
      var cur = null;
      try { var v = Number(sp.soundVolume()); if (isFinite(v)) cur = Math.round(v); } catch (e) {}
      if (cur === null || cur <= 0) cur = 50;
      writeFile(pre, String(cur));
    }
    sp.soundVolume = 0;
  } else {
    var restore = readPremute(data);
    removePath(pre);
    setVolume(sp, restore === null ? 50 : restore);
  }
}

function execCommand(data, name, arg) {
  if (name === 'open') {
    try { return $.NSWorkspace.sharedWorkspace.launchApplication(APP_NAME) ? '' : 'Failed to open Spotify'; }
    catch (e) { return 'Failed to open Spotify'; }
  }
  if (!canReachSpotify()) return "Spotify isn't running";

  var sp;
  try { sp = Application(BUNDLE_ID); } catch (e) { return "Spotify isn't running"; }

  try {
    switch (name) {
      case 'toggle': sp.playpause(); break;
      case 'play': sp.play(); break;
      case 'pause': sp.pause(); break;
      case 'next': sp.nextTrack(); break;
      case 'previous': sp.previousTrack(); break;
      case 'seek': {
        var ms = parseInt(arg, 10);
        if (!isFinite(ms)) return 'Invalid seek position';
        if (ms < 0) ms = 0;
        sp.playerPosition = ms / 1000;
        break;
      }
      case 'shuffle': {
        if (arg !== '0' && arg !== '1') return 'Invalid shuffle argument';
        if (!sp.shufflingEnabled()) return "Shuffle isn't available";
        sp.shuffling = (arg === '1');
        break;
      }
      case 'repeat': {
        if (arg !== 'off' && arg !== 'context' && arg !== 'track') return 'Invalid repeat argument';
        if (!sp.repeatingEnabled()) return "Repeat isn't available";
        // Spotify only has on/off, so both context + the track mean on
        sp.repeating = (arg !== 'off');
        break;
      }
      case 'volume': {
        var vol = parseInt(arg, 10);
        if (!isFinite(vol)) return 'Invalid volume';
        setVolume(sp, vol);
        if (exists(premutePath(data))) writeFile(premutePath(data), String(Math.max(0, Math.min(100, Math.round(vol)))));
        break;
      }
      case 'mute': {
        if (arg !== '0' && arg !== '1') return 'Invalid mute argument';
        applyMute(data, sp, arg === '1');
        break;
      }
      default: return 'Unknown command ' + name;
    }
  } catch (e) {
    markDown();
    return "Spotify isn't running";
  }
  return '';
}

function processCommands(data) {
  var cmdDir = data + '/cmd';
  var results = [];
  var files = listDir(cmdDir);
  files.sort();
  for (var i = 0; i < files.length; i++) {
    var file = files[i];
    if (!/\.cmd$/.test(file)) continue;
    var src = cmdDir + '/' + file;
    var work = src + '.work';
    if (!movePath(src, work)) continue;

    try {
      var id = file.replace(/\.cmd$/, '');
      var dash = id.indexOf('-');
      var written = parseInt(dash >= 0 ? id.slice(0, dash) : id, 10);
      var age = isFinite(written) ? (nowSec() - written) : CMD_STALE_SECS + 1;

      var content = readFile(work) || '';
      var lines = content.split(/\r?\n/);
      var name = (lines[0] || '').trim();
      var arg = (lines[1] || '').trim();

      if (name === '' && age < CMD_YOUNG_SECS) {
        if (!movePath(work, src)) removePath(work);
        continue;
      }
      if (name === '' || age > CMD_STALE_SECS) continue;

      var err = execCommand(data, name, arg);
      results.push({ id: id, error: err });
    } finally {
      removePath(work);
    }
  }
  return results;
}

function leaseIsAlive(data, startMs) {
  var raw = readFile(data + '/lease');
  var v = raw === null ? NaN : parseInt(String(raw).trim(), 10);
  if (isFinite(v) && (nowSec() - v) <= LEASE_TIMEOUT) return true;
  return (nowMs() - startMs) <= START_GRACE * 1000;
}

function acquireLock(data) {
  var lock = data + '/helper.lock';
  if (mkdir(lock, false)) return true;
  var state = readFile(data + '/state.txt');
  var beat = parseInt(parseKey(state, 'beat'), 10);
  if (!isFinite(beat) || (nowSec() - beat) > STALE_LOCK_SECS) {
    removePath(lock);
    if (mkdir(lock, false)) return true;
  }
  return false;
}

var ORDER = [
  'v', 'backend', 'beat', 'pid', 'seq', 'running', 'status', 'title', 'artist',
  'album', 'track_id', 'duration_ms', 'position_ms', 'pos_seq', 'shuffle',
  'repeat', 'volume', 'muted', 'can_play', 'can_next', 'can_prev', 'can_seek',
  'can_shuffle', 'can_repeat', 'can_volume', 'can_mute', 'art_file', 'art_url',
  'art_key', 'ack', 'error', 'problem'
];

function isVolatile(key) { return key === 'beat' || key === 'position_ms'; }

function loop(data, startMs) {
  var pid = Number($.NSProcessInfo.processInfo.processIdentifier);

  var seq = 0, posSeq = 0;
  var ack = '', cmdError = '';

  var prevTrackId = '', prevStatus = '';
  var posValid = false, posBase = 0, posBaseMs = 0, posPlaying = false;

  var lastBody = null, lastWriteMs = 0;

  for (;;) {
    if (!leaseIsAlive(data, startMs)) return;

    var results = processCommands(data);
    for (var ri = 0; ri < results.length; ri++) {
      ack = results[ri].id;
      cmdError = results[ri].error;
    }

    var running = false, st = null;
    if (canReachSpotify()) {
      st = readSpotify();
      if (st === null) {
        if (!spotifyRunning()) markDown();
        running = false;
      } else {
        running = true;
      }
    }

    var now = nowMs();
    var status = running ? normalizeStatus(st.status) : '';

    var title = '', artist = '', album = '', trackId = '', durationMs = '';
    var artUrl = '', shuffle = '', repeat = '', volume = '';
    var posMsValue = '';

    if (running && st) {
      title = txt(st.title);
      artist = txt(st.artist);
      album = txt(st.album);
      artUrl = txt(st.artworkUrl);
      var hasTrack = (st.trackId !== '' || title !== '' || artist !== '');
      if (hasTrack) {
        trackId = st.trackId !== '' ? st.trackId : (title + '|' + artist + '|' + album);
        if (st.duration !== null && st.duration > 0) durationMs = String(Math.round(st.duration));
      }

      var playing = (status === 'playing');

      var trackChanged = (trackId !== prevTrackId);
      var statusChanged = (status !== prevStatus);

      if (st.position !== null && hasTrack) {
        var readMs = Math.round(st.position * 1000);
        var expected = posValid ? (posPlaying ? posBase + (now - posBaseMs) : posBase) : null;
        var jumped = (expected === null) || Math.abs(readMs - expected) > POS_JUMP_MS;
        if (trackChanged || statusChanged || jumped) posSeq++;

        var posOut = playing ? (readMs + (nowMs() - now)) : readMs;
        if (durationMs !== '') {
          var dur = parseInt(durationMs, 10);
          if (isFinite(dur) && dur > 0 && posOut > dur) posOut = dur;
        }
        if (posOut < 0) posOut = 0;
        posMsValue = String(Math.round(posOut));
        posBase = readMs; posBaseMs = now; posPlaying = playing; posValid = true;
      } else {
        if (trackChanged || statusChanged) posSeq++;
        posValid = false; posPlaying = false;
      }

      if (st.shuffle !== null) shuffle = st.shuffle ? '1' : '0';
      if (st.repeatOn !== null) repeat = st.repeatOn ? 'context' : 'off';
      if (st.volume !== null) volume = String(Math.round(st.volume));
    } else {
      if ((trackId !== prevTrackId) || (status !== prevStatus)) posSeq++;
      posValid = false; posPlaying = false;
    }

    var canTrack = running && trackId !== '';
    var canShuffle = (canTrack && !(st && st.shuffleEnabled === false)) ? 1 : 0;
    var canRepeat = (canTrack && !(st && st.repeatEnabled === false)) ? 1 : 0;
    var canMute = running ? 1 : 0;

    var mutedVal = '';
    if (running) {
      var muted = exists(premutePath(data)) && volume === '0';
      mutedVal = muted ? '1' : '0';
    }

    var vals = {
      v: '1',
      backend: 'macos',
      pid: String(pid),
      running: running ? '1' : '0',
      status: clean(status),
      title: clean(title),
      artist: clean(artist),
      album: clean(album),
      track_id: clean(trackId),
      duration_ms: durationMs,
      pos_seq: String(posSeq),
      shuffle: shuffle,
      repeat: repeat,
      volume: volume,
      muted: mutedVal,
      can_play: canTrack ? '1' : '0',
      can_next: canTrack ? '1' : '0',
      can_prev: canTrack ? '1' : '0',
      can_seek: canTrack ? '1' : '0',
      can_shuffle: String(canShuffle),
      can_repeat: String(canRepeat),
      can_volume: canTrack ? '1' : '0',
      can_mute: String(canMute),
      art_file: '',
      art_url: clean(artUrl),
      art_key: clean(artUrl),
      ack: clean(ack),
      error: clean(cmdError),
      problem: ''
    };

    var bodyParts = [];
    for (var bi = 0; bi < ORDER.length; bi++) {
      var bk = ORDER[bi];
      if (isVolatile(bk) || bk === 'seq') continue;
      bodyParts.push(bk + '=' + vals[bk]);
    }
    var body = bodyParts.join('\n');
    var changed = (body !== lastBody);
    if (changed) seq++;
    lastBody = body;
    vals.seq = String(seq);
    vals.beat = String(nowSec());
    vals.position_ms = posMsValue;

    var playingNow = (status === 'playing');
    var heartbeat = playingNow ? 1000 : 2000;
    if (changed || (nowMs() - lastWriteMs) >= heartbeat) {
      var out = [];
      for (var oi = 0; oi < ORDER.length; oi++) out.push(ORDER[oi] + '=' + vals[ORDER[oi]]);
      if (atomicWrite(data + '/state.txt', out.join('\n') + '\n')) lastWriteMs = nowMs();
    }

    prevTrackId = trackId;
    prevStatus = status;

    sleepSeconds(LOOP_DELAY);
  }
}

function run(argv) {
  var data = (argv && argv.length > 0) ? String(argv[0]) : '';
  if (!data) return;
  if (data.length > 1 && data.charAt(data.length - 1) === '/') data = data.slice(0, -1);

  main(data);
  return;
}

function main(data) {
  try {
    mkdir(data, true);
    mkdir(data + '/cmd', true);

    if (!acquireLock(data)) return;

    var lock = data + '/helper.lock';
    var startMs = nowMs();
    try {
      loop(data, startMs);
    } catch (e) {
      logErr(data, 'fatal: ' + (e && e.message ? e.message : e));
    } finally {
      removePath(lock);
    }
  } catch (e) {
    logErr(data, 'fatal: ' + (e && e.message ? e.message : e));
  }
}
