import Foundation

/// The few lines Muro adds to every interactive wallpaper's page before the
/// page's own code runs (issue #59).
///
/// An interactive wallpaper sits under the desktop icons in a window that lets
/// every click through, so the page never gets a real mouse event, and a page
/// cannot hear the Mac's sound by itself. This is what tells it both, and what
/// lets Muro stop it the way it stops a video.
///
/// What a page can use:
///
/// - `muro:mouse` with `{x, y, inside}`: where the pointer is on this display,
///   0 to 1 from the top left. `inside` is true only while the pointer is on
///   this display's desktop itself. When it goes over an app window or to
///   another display the page is told once, with `inside` false, and then
///   nothing until it is back: somebody at work in an app is not playing with
///   the wallpaper behind it. The same is in `muro.mouse`.
/// - `muro:click` with `{x, y}`: a click on this display.
/// - `muro:audio` with `{bands, bass, mid, treble, level, playing}`: what the
///   Mac is playing, 64 bands from the low notes to the high ones, each 0 to
///   1. The same is in `muro.audio`. Muro only starts listening for a page
///   that asks for this event.
/// - `muro:pause` and `muro:resume`.
///
/// A page written for a browser hears the pointer too: every move and click is
/// also given to it as the ordinary `mousemove`, `mousedown`, `mouseup` and
/// `click` events, at the place the pointer is. A page written for Wallpaper
/// Engine or Lively gets its sound through the listener it already has
/// (`wallpaperRegisterAudioListener`, `livelyAudioListener`).
///
/// While Muro has the page paused, `requestAnimationFrame` holds its callbacks
/// instead of running them, CSS animations stop and videos pause, so a page
/// nobody can see costs nothing whether or not it was written with Muro in
/// mind.
public enum InteractiveBridge {
    /// How many bands of sound a page is given.
    public static let bandCount = 64
    /// The name of the page's way to tell Muro something.
    public static let handlerName = "muro"

    public static let script = """
    (function () {
      'use strict';
      if (window.muro) return;
      var N = \(bandCount);
      var tell = function (what) {
        try { window.webkit.messageHandlers.\(handlerName).postMessage(what); } catch (e) {}
      };
      var zeros = function () { var a = []; for (var i = 0; i < N; i++) a.push(0); return a; };
      var muro = {
        version: 1,
        paused: false,
        mouse: { x: 0.5, y: 0.5, inside: false },
        audio: { bands: zeros(), bass: 0, mid: 0, treble: 0, level: 0, playing: false },
        on: function (name, fn) {
          window.addEventListener('muro:' + name, function (e) { fn(e.detail); });
        }
      };
      window.muro = muro;
      var send = function (name, detail) {
        window.dispatchEvent(new CustomEvent('muro:' + name, { detail: detail }));
      };

      // Sound is listened to only for a page that asks for it.
      var wantsAudio = false;
      var askForAudio = function () {
        if (wantsAudio) return;
        wantsAudio = true;
        tell({ type: 'audio' });
      };
      var add = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = function (type) {
        if (type === 'muro:audio') askForAudio();
        return add.apply(this, arguments);
      };
      var engineListener = null;
      window.wallpaperRegisterAudioListener = function (fn) {
        engineListener = typeof fn === 'function' ? fn : null;
        if (engineListener) askForAudio();
      };
      var livelyListener = function () {
        return typeof window.livelyAudioListener === 'function' ? window.livelyAudioListener : null;
      };
      var lookForLively = function () { if (livelyListener()) askForAudio(); };
      add.call(document, 'DOMContentLoaded', lookForLively);
      add.call(window, 'load', lookForLively);

      muro.__audio = function (bands) {
        var a = muro.audio, low = 0, mid = 0, high = 0, all = 0;
        for (var i = 0; i < N; i++) {
          var v = bands[i] || 0;
          all += v;
          if (i < 10) low += v; else if (i < 38) mid += v; else high += v;
        }
        a.bands = bands;
        a.bass = low / 10;
        a.mid = mid / 28;
        a.treble = high / (N - 38);
        a.level = all / N;
        a.playing = a.level > 0.004;
        send('audio', a);
        var lively = livelyListener();
        if (engineListener || lively) {
          var both = bands.concat(bands);
          if (engineListener) { try { engineListener(both); } catch (e) {} }
          if (lively) { try { lively(both); } catch (e) {} }
        }
      };

      // The pointer, as Muro's own event and as the events a browser gives.
      var fire = function (target, type, x, y, dx, dy, button) {
        var init = {
          bubbles: true, cancelable: true, composed: true, view: window,
          clientX: x, clientY: y, screenX: x, screenY: y,
          movementX: dx, movementY: dy, button: button || 0,
          buttons: type === 'mousedown' || type === 'pointerdown' ? 1 : 0
        };
        try {
          if (type.indexOf('pointer') === 0) {
            init.pointerId = 1; init.pointerType = 'mouse'; init.isPrimary = true;
            target.dispatchEvent(new PointerEvent(type, init));
          } else {
            target.dispatchEvent(new MouseEvent(type, init));
          }
        } catch (e) {}
      };
      var under = function (x, y) {
        return document.elementFromPoint(x, y) || document.documentElement || document;
      };
      var lastX = 0, lastY = 0;
      muro.__mouse = function (x, y, inside) {
        var m = muro.mouse, was = m.inside;
        m.x = x; m.y = y; m.inside = inside;
        send('mouse', { x: x, y: y, inside: inside });
        var cx = x * window.innerWidth, cy = y * window.innerHeight;
        if (inside) {
          var target = under(cx, cy);
          fire(target, 'pointermove', cx, cy, cx - lastX, cy - lastY);
          fire(target, 'mousemove', cx, cy, cx - lastX, cy - lastY);
        } else if (was) {
          var root = document.documentElement || document;
          fire(root, 'pointerout', cx, cy, 0, 0);
          fire(root, 'mouseout', cx, cy, 0, 0);
          fire(root, 'mouseleave', cx, cy, 0, 0);
        }
        lastX = cx; lastY = cy;
      };
      muro.__click = function (x, y) {
        send('click', { x: x, y: y });
        var cx = x * window.innerWidth, cy = y * window.innerHeight;
        var target = under(cx, cy);
        fire(target, 'pointerdown', cx, cy, 0, 0);
        fire(target, 'mousedown', cx, cy, 0, 0);
        fire(target, 'pointerup', cx, cy, 0, 0);
        fire(target, 'mouseup', cx, cy, 0, 0);
        fire(target, 'click', cx, cy, 0, 0);
      };

      // Paused: the page's frames wait instead of being drawn.
      var frame = window.requestAnimationFrame.bind(window);
      var cancel = window.cancelAnimationFrame.bind(window);
      var held = new Map(), count = 0, stopped = [], style = null;
      window.requestAnimationFrame = function (fn) {
        if (!muro.paused) return frame(fn);
        count += 1;
        held.set(-count, fn);
        return -count;
      };
      window.cancelAnimationFrame = function (id) {
        if (id < 0) held.delete(id); else cancel(id);
      };
      muro.__pause = function (paused) {
        if (paused === muro.paused) return;
        muro.paused = paused;
        if (!style) {
          style = document.createElement('style');
          style.textContent = 'html.muro-paused *,html.muro-paused *::before,' +
            'html.muro-paused *::after{animation-play-state:paused!important}';
          (document.head || document.documentElement).appendChild(style);
        }
        if (document.documentElement) {
          document.documentElement.classList.toggle('muro-paused', paused);
        }
        if (paused) {
          stopped = [];
          var media = document.querySelectorAll('video,audio');
          for (var i = 0; i < media.length; i++) {
            if (!media[i].paused) { stopped.push(media[i]); media[i].pause(); }
          }
        } else {
          var waiting = held;
          held = new Map();
          waiting.forEach(function (fn) { frame(fn); });
          for (var j = 0; j < stopped.length; j++) {
            try { var p = stopped[j].play(); if (p && p.catch) p.catch(function () {}); } catch (e) {}
          }
          stopped = [];
        }
        send(paused ? 'pause' : 'resume', {});
      };
    })();
    """
}
