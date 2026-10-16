// The bookmark ribbon as fabric: gold grosgrain hanging from the top of the page, which the pointer pushes aside and
// which swings back. It moves as a bookmark ribbon does, like a heavy pendulum damped by the air whose lower part
// trails a little behind, so that is all it is: a swing and a bend, each a damped spring. WebGL draws it as a woven
// strip, lit so that its sheen shifts as it swings. Without WebGL the CSS ribbon stays, and with reduced motion the
// fabric hangs still. Sizes and colours come from the stylesheet (.ribbon and its custom properties).
(function () {
  "use strict";

  var ribbon = document.querySelector(".ribbon");
  if (!ribbon) return;
  var canvas = document.createElement("canvas");
  var gl = canvas.getContext("webgl", {
    alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: "low-power"
  });
  if (!gl) return;

  var NODES = 24;               // points along the ribbon, for drawing it
  var MAX_STEP = 1 / 120;       // s; the motion is worked out in steps no longer than this
  // The swing, the angle at which the ribbon hangs from the page's edge: near critically damped, so after a push it
  // comes back without swinging past and hangs still again within about a second.
  var SWING = 4.2;              // rad/s, its natural frequency
  var SWING_DAMPING = 0.8;      // of critical damping
  var MAX_SWING = 0.55;         // rad; pushed further, the ribbon slides off the pointer
  var MAX_SPEED = 2.2;          // rad/s; a pointer that would move it faster slips past instead of carrying it
  // The bend: when the swing speeds up or slows down, the lower part trails behind, then catches up.
  var BEND = 9, BEND_DAMPING = 0.9, TRAIL = 0.3, MAX_BEND = 0.3;
  var ROOT = 0.18;              // the part of its length over which the ribbon turns away from the page's edge
  // The drape: below where the pointer presses, the fabric hangs back down, over WRAP of its length.
  var DRAPE = 0.85, DRAPE_SPEED = 9, WRAP = 0.12;
  var BRUSH = 1 / 900;          // rad/s of swing per px/s of a pointer slipping past it, at its end
  var MAX_NUDGE = 1.4;          // rad/s
  var MOUSE_RADIUS = 6, TOUCH_RADIUS = 14;
  var DELAY = 0.15, UNROLL = 0.95; // s, as the CSS ribbon's animation
  var SEGMENT_SAMPLES = 5;      // points of the smoothed curve between two nodes

  // ---------- Drawing ----------

  var vertexShader = [
    "attribute vec2 aPos;",
    "attribute vec2 aUV;",
    "attribute vec2 aT;",
    "uniform vec3 uView;", // the pin's x on the canvas, the canvas's width and height, all in CSS px
    "varying vec2 vUV;",
    "varying vec2 vT;",
    "void main() {",
    "  vUV = aUV; vT = aT;",
    "  gl_Position = vec4((aPos.x + uView.x) / uView.y * 2.0 - 1.0, 1.0 - aPos.y / uView.z * 2.0, 0.0, 1.0);",
    "}"
  ].join("\n");

  // u runs across the ribbon (0 to 1), v along it in CSS px of fabric from the top; y points down.
  var fragmentShader = [
    "#extension GL_OES_standard_derivatives : enable",
    "#ifdef GL_FRAGMENT_PRECISION_HIGH",
    "precision highp float;",
    "#else",
    "precision mediump float;",
    "#endif",
    "varying vec2 vUV;",
    "varying vec2 vT;",
    "uniform vec3 uBase;",  // linear
    "uniform vec3 uSheen;", // linear
    "uniform vec4 uShape;", // width, the tip's v, notch depth, rib spacing (CSS px)
    "uniform vec2 uPixel;", // one device pixel in CSS px, and the width of a warp thread
    "float hash(float n) { return fract(sin(n * 91.3458) * 47453.5453); }",
    "float noise(vec2 p) {",
    "  vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);",
    "  float n = i.x + i.y * 57.0;",
    "  return mix(mix(hash(n), hash(n + 1.0), f.x), mix(hash(n + 57.0), hash(n + 58.0), f.x), f.y);",
    "}",
    "void main() {",
    "  float u = vUV.x, v = vUV.y, w = uShape.x;",
    // Coverage: the two sides, and the swallowtail notch cut into the end.
    "  float end = uShape.y - uShape.z * (1.0 - abs(2.0 * clamp(u, 0.0, 1.0) - 1.0)) - v;",
    "#ifdef GL_OES_standard_derivatives",
    "  float du = fwidth(u), dv = fwidth(v), de = fwidth(end);",
    "#else",
    "  float du = uPixel.x / w, dv = uPixel.x, de = uPixel.x;",
    "#endif",
    "  float alpha = clamp(min(u, 1.0 - u) / du + 0.5, 0.0, 1.0) * clamp(end / de + 0.5, 0.0, 1.0);",
    "  if (alpha <= 0.0) discard;",
    "  float x = clamp(u, 0.0, 1.0) * w;",
    // Grosgrain: fine ribs across, faded out where they would get finer than the pixels.
    "  float phase = 6.2831853 * v / uShape.w;",
    "  float fade = 1.0 - smoothstep(0.3, 0.6, dv / uShape.w);",
    "  float rib = sin(phase) * fade, slope = cos(phase) * fade;",
    // Warp threads along it, each a shade different, with slubs; and the woven edges.
    "  float thread = floor(x / uPixel.y);",
    "  float tone = hash(thread + 0.5) - 0.5;",
    "  float slub = noise(vec2(thread * 3.17, v / 5.0)) - 0.5;",
    "  float selvedge = 1.0 - smoothstep(0.4, 1.3, min(x, w - x));",
    // The surface: curled across its width like a ribbon that has lain in a book, and rippled by the ribs.
    "  vec3 T = vec3(normalize(vT), 0.0);",
    "  vec3 A = vec3(T.y, -T.x, 0.0);",
    "  float a = (clamp(u, 0.0, 1.0) - 0.5) * 2.0;",
    "  vec3 N = normalize(A * sin(a) + vec3(0.0, 0.0, cos(a)) - T * slope * 0.05);",
    "  vec3 yarn = normalize(T + vec3(0.0, 0.0, slope * 0.05));", // the warp rises and falls over the ribs
    "  vec3 L = normalize(vec3(-0.15, -0.45, 1.0));",
    "  vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));",
    "  float diffuse = max(dot(N, L), 0.0);",
    "  float th = dot(yarn, H);", // satin sheen along the threads (Kajiya-Kay)
    "  float sheen = pow(sqrt(max(1.0 - th * th, 0.0)), 24.0) * pow(max(dot(N, H), 0.0), 6.0);",
    "  float gloss = pow(max(dot(N, H), 0.0), 28.0);",
    "  vec3 base = uBase * (1.0 + 0.05 * tone + 0.06 * slub) * (1.0 - 0.22 * selvedge) * (1.0 + 0.025 * rib);",
    "  vec3 colour = base * (0.15 + 0.95 * diffuse) + uSheen * (0.3 * sheen + 0.24 * gloss) * (1.0 + 0.12 * rib);",
    "  gl_FragColor = vec4(pow(colour, vec3(1.0 / 2.2)) * alpha, alpha);",
    "}"
  ].join("\n");

  function compile(type, source) {
    var shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    return gl.getShaderParameter(shader, gl.COMPILE_STATUS) ? shader : null;
  }

  gl.getExtension("OES_standard_derivatives");
  var vs = compile(gl.VERTEX_SHADER, vertexShader), fs = compile(gl.FRAGMENT_SHADER, fragmentShader);
  if (!vs || !fs) return;
  var program = gl.createProgram();
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return;
  gl.useProgram(program);

  var uniform = {};
  ["uView", "uBase", "uSheen", "uShape", "uPixel"].forEach(function (name) {
    uniform[name] = gl.getUniformLocation(program, name);
  });

  var FLOATS = 6; // x, y, u, v, tangent x, tangent y
  var samples = (NODES - 1) * SEGMENT_SAMPLES + 3; // the curve, and a little beyond each end for the edges' smoothing
  var vertices = new Float32Array(samples * 2 * FLOATS);
  var buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, vertices.byteLength, gl.DYNAMIC_DRAW);
  [["aPos", 2, 0], ["aUV", 2, 2], ["aT", 2, 4]].forEach(function (a) {
    var location = gl.getAttribLocation(program, a[0]);
    gl.enableVertexAttribArray(location);
    gl.vertexAttribPointer(location, a[1], gl.FLOAT, false, FLOATS * 4, a[2] * 4);
  });
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  gl.clearColor(0, 0, 0, 0);

  // ---------- Layout ----------

  var width, length, side, below, ratio, pinX, pinY, notch, ribs;

  // A colour from the stylesheet (#RRGGBB) in linear light.
  function linear(value, fallback) {
    var match = /^#([0-9a-f]{6})$/i.exec(value.trim()), hex = match ? match[1] : fallback;
    return [0, 2, 4].map(function (i) { return Math.pow(parseInt(hex.substr(i, 2), 16) / 255, 2.2); });
  }

  function layout() {
    var style = getComputedStyle(ribbon);
    width = ribbon.offsetWidth;
    length = ribbon.offsetHeight;
    // Room to swing to either side, but not past the window's right edge, where it would widen the page; and room for
    // the edges' smoothing below.
    var rect = ribbon.getBoundingClientRect();
    side = Math.round(length * 0.7);
    var right = Math.max(0, Math.min(side, Math.floor(document.documentElement.clientWidth - rect.right)));
    below = 6;
    ratio = Math.min(window.devicePixelRatio || 1, 3);
    var w = width + side + right, h = length + below;
    canvas.style.left = -side + "px";
    canvas.style.width = w + "px";
    canvas.style.height = h + "px";
    canvas.width = Math.round(w * ratio);
    canvas.height = Math.round(h * ratio);
    gl.viewport(0, 0, canvas.width, canvas.height);
    var pixel = 1 / ratio;
    gl.uniform3f(uniform.uView, side + width / 2, w, h);
    notch = parseFloat(style.getPropertyValue("--ribbon-notch")) || 13;
    // Ribs about 1.6 px apart, in whole device pixels so that hanging straight they don't beat against the pixels.
    ribs = Math.max(3, Math.round(1.6 * ratio)) * pixel;
    gl.uniform2f(uniform.uPixel, pixel, Math.max(0.85, 1.6 * pixel));
    gl.uniform3fv(uniform.uBase, linear(style.getPropertyValue("--ribbon"), "DC9C30"));
    gl.uniform3fv(uniform.uSheen, linear(style.getPropertyValue("--ribbon-sheen"), "FFF1C9"));
    pinX = rect.left + window.scrollX + width / 2;
    pinY = rect.top + window.scrollY;
  }

  // ---------- The motion ----------

  var swing = 0, swingSpeed = 0, bend = 0, bendSpeed = 0, drape = 0, drapeSpeed = 0;
  var holdAt = 1;       // where along the ribbon (0 to 1) the pointer presses, or last pressed
  var shown = 0;        // how much of the ribbon has unrolled, in px
  var started = 0;      // when the page opened, in ms
  // The ribbon as drawn: points along it from the pin (0, 0), with y pointing down.
  var x = new Float32Array(NODES), y = new Float32Array(NODES);

  function clamp(value, most) { return Math.max(-most, Math.min(most, value)); }

  // The fabric's angle from the vertical at t, from 0 at the page's edge to 1 at its end: turning away from the edge
  // over its first part, then the swing, hanging back down below the pointer, and the bend growing towards the end.
  function angle(t, s, b) {
    var r = Math.min(t / ROOT, 1), k = 0;
    if (drape && t > holdAt) { k = Math.min((t - holdAt) / WRAP, 1); k = k * k * (3 - 2 * k); }
    return s * (1 - (1 - r) * (1 - r)) * (1 - drape * k) + b * t * t;
  }

  // n points evenly along the fabric, following its angle.
  var FINE = 4; // steps between two points
  function lay(s, b, len, n, xs, ys) {
    var steps = (n - 1) * FINE, ds = len / steps, px = 0, py = 0;
    xs[0] = ys[0] = 0;
    for (var j = 0; j < steps; j++) {
      var a = angle((j + 0.5) / steps, s, b);
      px += Math.sin(a) * ds;
      py += Math.cos(a) * ds;
      if ((j + 1) % FINE === 0) { xs[(j + 1) / FINE] = px; ys[(j + 1) / FINE] = py; }
    }
  }

  // Where the ribbon crosses the height h, with swing s and bend b; NaN below its end.
  var probeX = new Float32Array(33), probeY = new Float32Array(33);
  function across(h, s, b) {
    if (h < 0) return NaN;
    lay(s, b, length, 33, probeX, probeY);
    for (var i = 1; i < 33; i++) {
      if (probeY[i] >= h) {
        var f = (h - probeY[i - 1]) / (probeY[i] - probeY[i - 1] || 1);
        return probeX[i - 1] + (probeX[i] - probeX[i - 1]) * f;
      }
    }
    return NaN;
  }

  // The pointer, as a disc that moved from a to b during a step. The ribbon rests against it and is pushed along as
  // far and as fast as fabric goes; beyond that the pointer slips past and leaves it a small nudge.
  var touching = 0;     // which side of the ribbon the pointer rests against: 1 right, -1 left
  var pressed = false;  // whether it held the ribbon back in this step
  var slipped = false;  // slipped past, until it is clear of the ribbon again

  function nudge(facing, ax, bx, by, h) {
    var speed = Math.abs(bx - ax) / h;
    swingSpeed = clamp(swingSpeed - facing * Math.min(speed * BRUSH, MAX_NUDGE) * by / length, MAX_SPEED);
    slipped = true;
    touching = 0;
  }

  function meet(ax, ay, bx, by, radius, before, h) {
    var reach = radius + width / 2, xb = across(by, swing, bend);
    if (isNaN(xb)) { touching = 0; slipped = false; return; }
    var xa = across(ay, swing, bend), da = isNaN(xa) ? bx - xb : ax - xa, db = bx - xb;
    if (Math.abs(db) >= reach) {
      // Clear of it; but if it went across the ribbon within one step, that was a quick brush.
      if (!touching && !slipped && da * db < 0) nudge(da > 0 ? 1 : -1, ax, bx, by, h);
      touching = 0;
      slipped = false;
      return;
    }
    if (slipped) return;
    var facing = touching || (da > 0 ? 1 : da < 0 ? -1 : db >= 0 ? 1 : -1), goal = bx - facing * reach;
    // The swing that puts the ribbon's edge just beside the pointer, if there is one within reach.
    var lo = -MAX_SWING, hi = MAX_SWING;
    var low = across(by, lo, bend) - goal, high = across(by, hi, bend) - goal;
    if (isNaN(low) || isNaN(high) || low > 0 || high < 0) { nudge(facing, ax, bx, by, h); return; }
    for (var k = 0; k < 14; k++) {
      var mid = (lo + hi) / 2;
      if (across(by, mid, bend) > goal) hi = mid; else lo = mid;
    }
    var want = (lo + hi) / 2;
    touching = facing;
    // It only ever holds the ribbon back from passing it; it never pulls.
    if ((want - swing) * facing >= 0) return;
    if (Math.abs(want - before) > MAX_SPEED * h) { nudge(facing, ax, bx, by, h); return; }
    swingSpeed = (want - before) / h;
    swing = want;
    pressed = true;
    holdAt = Math.max(ROOT, Math.min(1, by / Math.cos(swing) / length));
  }

  function step(h, pointer) {
    var before = swing, speed = swingSpeed;
    pressed = false;
    swingSpeed += (-SWING * SWING * Math.sin(swing) - 2 * SWING_DAMPING * SWING * swingSpeed) * h;
    swing += swingSpeed * h;
    if (pointer) meet(pointer[0], pointer[1], pointer[2], pointer[3], pointer[4], before, h);
    else touching = 0;
    swingSpeed = clamp(swingSpeed, MAX_SPEED);
    swing = clamp(swing, MAX_SWING);
    // The lower part trails behind the swing's changes of speed.
    var change = (swingSpeed - speed) / h;
    bendSpeed += (-BEND * BEND * bend - 2 * BEND_DAMPING * BEND * bendSpeed - TRAIL * change) * h;
    bend = clamp(bend + bendSpeed * h, MAX_BEND);
    // The more it is pushed over, the more the part below the pointer hangs back; let go, it straightens.
    var hanging = pressed ? DRAPE * Math.min(1, Math.abs(swing) / 0.15) : 0;
    drapeSpeed += (DRAPE_SPEED * DRAPE_SPEED * (hanging - drape) - 2 * DRAPE_SPEED * drapeSpeed) * h;
    drape = Math.max(0, Math.min(1, drape + drapeSpeed * h));
  }

  function hang(unrolled) {
    shown = unrolled;
    swing = swingSpeed = bend = bendSpeed = drape = drapeSpeed = 0;
    lay(0, 0, shown, NODES, x, y);
  }

  // ---------- The strip ----------

  var o = 0;
  function vertex(cx, cy, ax, ay, half, u, v, tx, ty) {
    vertices[o++] = cx + ax * half; vertices[o++] = cy + ay * half;
    vertices[o++] = u; vertices[o++] = v;
    vertices[o++] = tx; vertices[o++] = ty;
  }

  function pair(cx, cy, tx, ty, v) {
    var t = Math.sqrt(tx * tx + ty * ty) || 1;
    tx /= t; ty /= t;
    // A pixel more on each side leaves room for the edges' smoothing.
    var half = width / 2, extra = 1 / ratio, spread = 0.5 * (half + extra) / half;
    vertex(cx, cy, -ty, tx, half + extra, 0.5 - spread, v, tx, ty);
    vertex(cx, cy, ty, -tx, half + extra, 0.5 + spread, v, tx, ty);
  }

  function node(a, i) {
    if (i < 0) return 2 * a[0] - a[1];
    if (i >= NODES) return 2 * a[NODES - 1] - a[NODES - 2];
    return a[i];
  }

  // Catmull-Rom through the points: the point at i + f on one axis, and the curve's direction there.
  var at = 0, along = 0;
  function spline(a, i, f) {
    var p0 = node(a, i - 1), p1 = a[i], p2 = a[i + 1], p3 = node(a, i + 2);
    var b = p2 - p0, c = 2 * p0 - 5 * p1 + 4 * p2 - p3, e = 3 * (p1 - p2) + p3 - p0;
    at = 0.5 * (2 * p1 + b * f + c * f * f + e * f * f * f);
    along = 0.5 * (b + 2 * c * f + 3 * e * f * f);
  }

  function draw() {
    o = 0;
    var top = length - shown; // the fabric still above the page's edge, in px
    var last = (NODES - 1) * SEGMENT_SAMPLES, cx = 0, cy = 0, tx = 0, ty = 1;
    for (var s = 0; s <= last; s++) {
      var i = Math.min(Math.floor(s / SEGMENT_SAMPLES), NODES - 2), f = s / SEGMENT_SAMPLES - i;
      spline(x, i, f); cx = at; tx = along;
      spline(y, i, f); cy = at; ty = along;
      if (Math.abs(tx) + Math.abs(ty) < 1e-6) { tx = 0; ty = 1; }
      var v = top + (i + f) / (NODES - 1) * shown;
      // Begin above the page's edge, so that the canvas cuts the top cleanly.
      if (s === 0) pair(cx, cy - 3, tx, ty, v - 3);
      pair(cx, cy, tx, ty, v);
    }
    // And end a little past the tip, where the notch's smoothing needs room.
    var t = Math.sqrt(tx * tx + ty * ty);
    pair(cx + tx / t * 2, cy + ty / t * 2, tx, ty, length + 2);
    gl.uniform4f(uniform.uShape, width, length, notch, ribs);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, vertices);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, o / FLOATS);
  }

  // ---------- The pointer ----------

  // A mouse is followed in the window, so that scrolling moves the page under it; a finger in the page, since the
  // page moves with it.
  var pointer = { active: false, touch: false, x: 0, y: 0, radius: MOUSE_RADIUS };
  // Where the pointer was at the last step, and at the last event: a step sweeps from the one to where it is now.
  var from = null, seen = null;

  function pointerAt() {
    if (!pointer.active) return null;
    var sx = pointer.touch ? 0 : window.scrollX, sy = pointer.touch ? 0 : window.scrollY;
    return [pointer.x + sx - pinX, pointer.y + sy - pinY];
  }

  // Whether the pointer's way from a to b comes near the ribbon.
  function near(a, b) {
    var reach = pointer.radius + width, left = Infinity, right = -Infinity, bottom = -Infinity;
    for (var i = 0; i < NODES; i++) {
      left = Math.min(left, x[i]); right = Math.max(right, x[i]); bottom = Math.max(bottom, y[i]);
    }
    return Math.max(a[0], b[0]) > left - reach && Math.min(a[0], b[0]) < right + reach &&
      Math.min(a[1], b[1]) < bottom + reach;
  }

  function track() {
    var p = pointerAt();
    if (!frame) from = seen || p; // asleep, nothing followed the pointer: the step starts from the last event
    if (near(seen || p, p)) wake();
    seen = p;
  }

  function moved(clientX, clientY, touch) {
    if (!pointer.active || pointer.touch !== touch) from = seen = null;
    pointer.active = true;
    pointer.touch = touch;
    pointer.radius = touch ? TOUCH_RADIUS : MOUSE_RADIUS;
    pointer.x = clientX + (touch ? window.scrollX : 0);
    pointer.y = clientY + (touch ? window.scrollY : 0);
    track();
  }

  function released() {
    if (!pointer.active) return;
    pointer.active = false;
    from = seen = null;
    wake(); // to swing back
  }

  // ---------- Running ----------

  var frame = 0, last = 0, still = 0, visible = true, reduced = false, unrolled = false;
  var drawn = 0;
  var motion = window.matchMedia("(prefers-reduced-motion: reduce)");

  function wake() {
    if (frame || reduced || !visible || document.hidden) return;
    still = 0;
    last = performance.now();
    frame = requestAnimationFrame(tick);
  }

  var capsule = [0, 0, 0, 0, 0];

  function tick(now) {
    frame = 0;
    var dt = Math.max(0, Math.min((now - last) / 1000, 1 / 20));
    last = now;
    if (!unrolled) {
      // Straight out from under the page's edge, eased like the CSS ribbon; it moves once it's all out.
      var t = Math.max(0, Math.min(1, ((now - started) / 1000 - DELAY) / UNROLL));
      hang(length * (1 - Math.pow(1 - t, 3)));
      unrolled = t >= 1;
      draw();
      frame = requestAnimationFrame(tick);
      return;
    }
    shown = length;
    var to = pointerAt();
    if (to && !from) from = to;
    if (dt > 0) {
      var steps = Math.ceil(dt / MAX_STEP - 0.01) || 1, h = dt / steps;
      for (var k = 0; k < steps; k++) {
        if (to) {
          capsule[0] = from[0] + (to[0] - from[0]) * k / steps;
          capsule[1] = from[1] + (to[1] - from[1]) * k / steps;
          capsule[2] = from[0] + (to[0] - from[0]) * (k + 1) / steps;
          capsule[3] = from[1] + (to[1] - from[1]) * (k + 1) / steps;
          capsule[4] = pointer.radius;
        }
        step(h, to && capsule);
      }
    }
    from = to;
    var shape = swing + 3 * bend + 7 * drape;
    if (Math.abs(shape - drawn) > 1e-5) {
      lay(swing, bend, length, NODES, x, y);
      draw();
      drawn = shape;
    }
    // Asleep once it has hung still for a moment; the pointer, a resize or the page coming back wakes it.
    still = Math.abs(swingSpeed) + Math.abs(bendSpeed) + Math.abs(drapeSpeed) > 0.002 ? 0 : still + 1;
    if (still < 15) frame = requestAnimationFrame(tick);
  }

  function restart() {
    reduced = motion.matches;
    layout();
    if (reduced) {
      if (frame) { cancelAnimationFrame(frame); frame = 0; }
      unrolled = true;
      hang(length);
    } else if (unrolled) {
      shown = length;
      lay(swing, bend, length, NODES, x, y);
    }
    draw();
    wake();
  }

  ribbon.appendChild(canvas);
  ribbon.classList.add("live");
  reduced = motion.matches;
  unrolled = reduced;
  started = performance.now();
  layout();
  hang(reduced ? length : 0);
  draw();
  wake();

  var options = { passive: true };
  window.addEventListener("pointermove", function (e) {
    if (e.pointerType !== "touch") moved(e.clientX, e.clientY, false);
  }, options);
  document.documentElement.addEventListener("pointerleave", function (e) {
    if (e.pointerType !== "touch") released();
  }, options);
  window.addEventListener("blur", released);
  window.addEventListener("touchstart", function (e) {
    pointer.active = false;
    moved(e.touches[0].clientX, e.touches[0].clientY, true);
  }, options);
  window.addEventListener("touchmove", function (e) {
    moved(e.touches[0].clientX, e.touches[0].clientY, true);
  }, options);
  window.addEventListener("touchend", function (e) { if (!e.touches.length) released(); }, options);
  window.addEventListener("touchcancel", released, options);
  window.addEventListener("scroll", function () { if (pointer.active && !pointer.touch) track(); }, options);

  window.addEventListener("resize", restart);
  if (window.ResizeObserver) new ResizeObserver(function () { restart(); }).observe(ribbon);
  motion.addEventListener("change", restart);
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", restart);
  document.addEventListener("visibilitychange", function () { if (!document.hidden) wake(); });
  if (window.IntersectionObserver) {
    new IntersectionObserver(function (entries) {
      visible = entries[entries.length - 1].isIntersecting;
      if (visible) wake(); else if (frame) { cancelAnimationFrame(frame); frame = 0; }
    }).observe(canvas);
  }
  canvas.addEventListener("webglcontextlost", function (e) {
    // Back to the CSS ribbon.
    e.preventDefault();
    if (frame) cancelAnimationFrame(frame);
    reduced = true;
    ribbon.classList.remove("live");
    canvas.remove();
  });
})();
