// Introdução do SECADA: uma linha do tempo de 14 s, sem dependências.
// Tudo é função do tempo t (segundos), então qualquer quadro pode ser reproduzido com seek(t).
//
// Parâmetros de URL:
//   ?next=../       ao terminar, segue para esse endereço (só do mesmo site)
//   ?t=7.5          congela o quadro desse instante (útil para revisar a composição)
//
// Integração: ao terminar dispara o evento `secada:intro-end` em window e, se estiver num
// iframe, envia postMessage({ type: 'secada:intro-end' }) para a janela pai.
(() => {
  'use strict';

  const DURATION = 14;            // duração total, incluindo a transição de saída
  const EXIT_AT = 13.1;           // início da saída
  const SVGNS = 'http://www.w3.org/2000/svg';
  const LOGO = { cx: 828.5, cy: 485.5, w: 851, h: 423 };
  const BAND_Y = 495.5;           // linha central da faixa do nome

  const $ = (id) => document.getElementById(id);
  const svg = $('stage');
  const params = new URLSearchParams(location.search);

  // ---------- curvas de aceleração ----------
  const ease = {
    linear: (x) => x,
    outCubic: (x) => 1 - (1 - x) ** 3,
    inCubic: (x) => x ** 3,
    inOutCubic: (x) => (x < 0.5 ? 4 * x ** 3 : 1 - (-2 * x + 2) ** 3 / 2),
    inOutSine: (x) => -(Math.cos(Math.PI * x) - 1) / 2,
    outExpo: (x) => (x >= 1 ? 1 : 1 - 2 ** (-10 * x)),
    inOutExpo: (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x < 0.5 ? 2 ** (20 * x - 10) / 2 : (2 - 2 ** (-20 * x + 10)) / 2),
    outBack: (x) => { const c = 1.6; return 1 + (c + 1) * (x - 1) ** 3 + c * (x - 1) ** 2; },
    inOutBack: (x) => {
      const c = 1.1 * 1.525;
      return x < 0.5
        ? ((2 * x) ** 2 * ((c + 1) * 2 * x - c)) / 2
        : ((2 * x - 2) ** 2 * ((c + 1) * (x * 2 - 2) + c) + 2) / 2;
    },
  };
  const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);
  const ramp = (t, a, b) => clamp01((t - a) / (b - a));

  // ---------- motor de animação ----------
  // Cada trilha é uma lista de chaves [início, duração, de, para, curva]. Antes da primeira chave
  // vale o "de" dela; entre chaves vale o "para" da anterior.
  const DEFAULTS = { o: 1, x: 0, y: 0, s: 1, sx: 1, sy: 1, dash: 1 };
  const actors = [];

  function sample(keys, t) {
    let v = keys[0][2];
    for (const [t0, dur, from, to, fn] of keys) {
      if (t < t0) break;
      v = dur <= 0 || t >= t0 + dur ? to : from + (to - from) * (ease[fn || 'linear'])((t - t0) / dur);
    }
    return v;
  }

  function anim(target, tracks, origin = [0, 0]) {
    const el = typeof target === 'string' ? $(target) : target;
    const a = { el, tracks, origin, html: !(el instanceof SVGElement), last: {} };
    actors.push(a);
    return a;
  }

  function set(a, key, value) {
    if (a.last[key] === value) return;
    a.last[key] = value;
    if (key === 'transform') {
      if (a.html) a.el.style.transform = value; else a.el.setAttribute('transform', value);
    } else if (key === 'o') {
      // Opacidade 0 também esconde o elemento, para o navegador não pintar o que não aparece.
      if (a.html) { a.el.style.opacity = value; a.el.style.visibility = value ? '' : 'hidden'; } else {
        a.el.setAttribute('opacity', value);
        if (value) a.el.removeAttribute('visibility'); else a.el.setAttribute('visibility', 'hidden');
      }
    } else if (key === 'fo') {
      a.el.setAttribute('fill-opacity', value);
    } else if (key === 'dash') {
      a.el.style.strokeDashoffset = value;
    }
  }

  const r3 = (n) => Math.round(n * 1000) / 1000;

  function renderActors(t) {
    for (const a of actors) {
      const v = {};
      for (const k in a.tracks) v[k] = sample(a.tracks[k], t);
      if ('o' in v) set(a, 'o', r3(clamp01(v.o)));
      if ('fo' in v) set(a, 'fo', r3(clamp01(v.fo)));
      if ('dash' in v) set(a, 'dash', r3(1 - v.dash));
      if ('x' in v || 'y' in v || 's' in v || 'sx' in v || 'sy' in v) {
        const x = v.x ?? DEFAULTS.x, y = v.y ?? DEFAULTS.y, s = v.s ?? 1;
        const sx = (v.sx ?? 1) * s, sy = (v.sy ?? 1) * s;
        const [ox, oy] = a.origin;
        const u = a.unit || 1;
        set(a, 'transform', a.html
          ? `translate(${r3(x)}px,${r3(y)}px) scale(${r3(sx * u)},${r3(sy * u)})`
          : `translate(${r3(ox + x)} ${r3(oy + y)}) scale(${r3(sx) || 0.0001} ${r3(sy) || 0.0001}) translate(${-ox} ${-oy})`);
      }
    }
  }

  const el = (tag, attrs, parent) => {
    const n = document.createElementNS(SVGNS, tag);
    for (const k in attrs) n.setAttribute(k, attrs[k]);
    parent.appendChild(n);
    return n;
  };

  // ---------- coreografia ----------
  const C = [LOGO.cx, LOGO.cy];
  const BAND = [LOGO.cx, BAND_Y];

  // Atmosfera e câmera. A grade de pontos se afasta mais rápido que o resto (profundidade).
  anim(document.querySelector('.bg'), { o: [[0, 1.6, 0, 1, 'outCubic']] });
  const glow = anim('glow', {
    o: [[0.2, 2.2, 0, 0.45, 'outCubic'], [8.4, 2.0, 0.45, 1, 'inOutCubic'], [13.0, 1.0, 1, 0, 'inCubic']],
    s: [[8.4, 2.6, 0.92, 1.04, 'inOutSine']],
  });
  anim('cam', {
    s: [[0, 8.6, 1.045, 1, 'outCubic'], [8.8, 4.3, 1, 1.022, 'inOutSine'], [EXIT_AT, 0.9, 1.022, 1.05, 'inCubic']],
  }, C);
  anim('veil', { o: [[EXIT_AT + 0.05, 0.85, 0, 1, 'inCubic']] });

  // 0–2 s: inicialização. Ponto central, réguas, pulsos e grade.
  anim('core', { s: [[0.15, 0.45, 0, 1, 'outBack'], [2.1, 0.4, 1, 0, 'inCubic']], o: [[0.15, 0.2, 0, 1]] }, BAND);
  anim('core-ring', { s: [[1.25, 0.9, 1, 7, 'outCubic']], o: [[1.25, 0.05, 0, 0.9], [1.3, 0.85, 0.9, 0, 'outCubic']] }, BAND);
  anim('vline', { sy: [[0.6, 1.0, 0, 1, 'inOutCubic'], [1.95, 0.5, 1, 0, 'inCubic']] }, BAND);

  const grid = $('grid');
  anim(grid, { s: [[1.7, 2.0, 1, 1.22, 'inCubic']] }, BAND);
  const maxD = Math.hypot(10 * 64, 5 * 64);
  for (let j = -5; j <= 5; j++) {
    if (j === 0) continue;
    for (let i = -10; i <= 10; i++) {
      const d = Math.hypot(i * 64, j * 64) / maxD;
      const dot = el('circle', { cx: LOGO.cx + i * 64, cy: BAND_Y + j * 64, r: 1.3, opacity: 0 }, grid);
      const peak = 0.26 * (1 - 0.55 * d);
      anim(dot, { o: [[0.25 + d * 0.95, 0.5, 0, peak, 'outCubic'], [2.05 + (1 - d) * 0.75, 0.4, peak, 0, 'inCubic']] });
    }
  }

  const ticks = $('ticks');
  for (let i = -17; i <= 17; i++) {
    const x = LOGO.cx + i * 32, major = i % 4 === 0, h = major ? 7 : 3.5, k = Math.abs(i);
    const tick = el('line', { x1: x, x2: x, y1: BAND_Y - h, y2: BAND_Y + h, 'stroke-opacity': major ? 0.6 : 0.35, opacity: 0 }, ticks);
    anim(tick, {
      sy: [[0.72 + k * 0.026, 0.35, 0, 1, 'outCubic']],
      o: [[0.72 + k * 0.026, 0.2, 0, 1], [2.05 + (17 - k) * 0.014, 0.26, 1, 0]],
    }, [x, BAND_Y]);
  }

  const pulses = $('pulses');
  [[-1, 0], [1, 0], [-1, 0.16], [1, 0.16]].forEach(([dir, delay]) => {
    const p = el('line', { x1: LOGO.cx, x2: LOGO.cx + dir * 34, y1: BAND_Y, y2: BAND_Y, opacity: 0 }, pulses);
    const t0 = 1.12 + delay;
    anim(p, {
      x: [[t0, 1.0, 0, dir * 520, 'inOutCubic']],
      o: [[t0, 0.15, 0, delay ? 0.5 : 0.95], [t0 + 0.7, 0.3, delay ? 0.5 : 0.95, 0]],
    });
  });

  // Cantoneiras que enquadram a composição e depois se fecham sobre a marca.
  const brackets = $('brackets');
  const F = { l: 377, r: 1280, t: 248, b: 723, arm: 26 };
  [
    [`M${F.l} ${F.t + F.arm}V${F.t}H${F.l + F.arm}`, -1, -1],
    [`M${F.r - F.arm} ${F.t}H${F.r}V${F.t + F.arm}`, 1, -1],
    [`M${F.r} ${F.b - F.arm}V${F.b}H${F.r - F.arm}`, 1, 1],
    [`M${F.l + F.arm} ${F.b}H${F.l}V${F.b - F.arm}`, -1, 1],
  ].forEach(([d, sx, sy], i) => {
    const b = el('path', { d, pathLength: 1, 'stroke-dasharray': '1 1', opacity: 0 }, brackets);
    const t0 = 0.9 + i * 0.08, ox = sx * 120, oy = sy * 64;
    anim(b, {
      dash: [[t0, 0.6, 0, 1, 'outCubic']],
      o: [[t0, 0.2, 0, 1], [7.9, 0.7, 1, 0, 'inOutSine']],
      x: [[t0, 0.6, ox * 1.25, ox, 'outCubic'], [2.2, 1.1, ox, 0, 'outExpo'], [7.9, 0.7, 0, sx * 14, 'inOutSine']],
      y: [[t0, 0.6, oy * 1.25, oy, 'outCubic'], [2.2, 1.1, oy, 0, 'outExpo'], [7.9, 0.7, 0, sy * 10, 'inOutSine']],
    });
  });

  // Trilhos: a régua central se divide em dois trilhos que delimitam a faixa do nome.
  const RAIL_HALF = 560, NAME_HALF = 415.5;
  const railFit = NAME_HALF / RAIL_HALF;
  anim('rail-top', {
    sx: [[0.32, 1.15, 0, 1, 'inOutExpo'], [2.65, 0.85, 1, railFit, 'outCubic'], [8.0, 0.8, railFit, 0, 'inOutCubic']],
    x: [[8.0, 0.8, 0, NAME_HALF, 'inOutCubic']],
    y: [[2.25, 0.85, 0, 449 - BAND_Y, 'inOutBack']],
    o: [[8.5, 0.3, 1, 0]],
  }, BAND);
  anim('rail-bottom', {
    sx: [[0.32, 1.15, 0, 1, 'inOutExpo'], [2.65, 0.85, 1, railFit, 'outCubic'], [8.08, 0.8, railFit, 0, 'inOutCubic']],
    x: [[8.08, 0.8, 0, -NAME_HALF, 'inOutCubic']],
    y: [[2.3, 0.85, 0, 543 - BAND_Y, 'inOutBack']],
    o: [[8.58, 0.3, 1, 0]],
  }, BAND);

  // 2–5 s: construção. Planos inclinados (no ângulo dos cortes do símbolo) deslizam até o lugar
  // das duas metades do "S" e o contorno de cada metade é traçado.
  anim('plane-top', {
    x: [[2.55, 1.2, 320, 0, 'outExpo']], y: [[2.55, 1.2, -320, 0, 'outExpo']],
    o: [[2.55, 0.5, 0, 1], [4.95, 0.8, 1, 0, 'inOutCubic']],
  });
  anim('plane-bottom', {
    x: [[2.7, 1.2, -320, 0, 'outExpo']], y: [[2.7, 1.2, 320, 0, 'outExpo']],
    o: [[2.7, 0.5, 0, 1], [5.05, 0.8, 1, 0, 'inOutCubic']],
  });
  anim('top-line', { dash: [[3.2, 1.7, 0, 1, 'inOutCubic']], o: [[3.2, 0.1, 0, 1], [5.8, 0.6, 1, 0]] });
  anim('bottom-line', { dash: [[3.4, 1.7, 0, 1, 'inOutCubic']], o: [[3.4, 0.1, 0, 1], [5.9, 0.6, 1, 0]] });

  // 5–8 s: identidade. As metades recuam (antecipação), avançam até a posição final e são
  // preenchidas por máscaras inclinadas em sentidos opostos.
  const dimKeys = [[8.6, 0.6, 1, 0.74, 'inOutSine'], [10.0, 0.9, 0.74, 1, 'inOutSine']];
  anim('top', { x: [[0, 0, 44, 44], [4.7, 0.25, 44, 58, 'outCubic'], [4.95, 1.25, 58, 0, 'outExpo']], fo: dimKeys });
  anim('bottom', { x: [[0, 0, -44, -44], [4.82, 0.25, -44, -58, 'outCubic'], [5.07, 1.25, -58, 0, 'outExpo']], fo: dimKeys });
  anim('wipe-top', { x: [[4.95, 1.15, 1171, 440, 'inOutCubic']], y: [[0, 0, 362, 362]] });
  anim('wipe-bottom', { x: [[5.07, 1.15, 480, 1200, 'inOutCubic']], y: [[0, 0, 619, 619]] });

  // O nome sobe por trás do trilho inferior, letra a letra; a barra do E desce do trilho superior.
  anim('letters', { fo: dimKeys });
  ['l-s', 'l-e', 'l-c', 'l-a1', 'l-d', 'l-a2'].forEach((id, k) => {
    const t0 = 6.15 + k * 0.1;
    anim(id, { y: [[t0, 1.0, 104, 0, 'outExpo']], o: [[t0, 0.3, 0, 1]] });
  });
  anim('l-ebar', { y: [[6.5, 1.0, -96, 0, 'outExpo']], o: [[6.5, 0.3, 0, 1]] });

  // 9–12 s: momento principal. Passagem de luz recortada pela marca, brilho e respiração.
  anim('sweep-wrap', { o: [[0, 0, 0, 0], [8.9, 0, 0, 1], [10.9, 0, 1, 0]] });
  anim('sweep', { x: [[8.95, 1.7, -60, 1720, 'inOutSine']], y: [[0, 0, LOGO.cy, LOGO.cy]], o: [[0, 0, 0, 0], [8.95, 0, 0, 1], [10.65, 0, 1, 0]] });
  anim('sweep-thin', { x: [[9.15, 1.7, 60, 1660, 'inOutSine']], y: [[0, 0, LOGO.cy, LOGO.cy]], o: [[0, 0, 0, 0], [9.15, 0, 0, 0.8], [10.85, 0, 0.8, 0]] });
  anim('sweep-haze', {
    x: [[8.95, 1.6, 0, 1660, 'inOutCubic']], y: [[0, 0, LOGO.cy, LOGO.cy]],
    o: [[8.95, 0.4, 0, 1], [10.15, 0.4, 1, 0]],
  });
  anim('bloom', { o: [[9.5, 1.1, 0, 0.5, 'outCubic'], [10.6, 1.4, 0.5, 0.22, 'inOutSine'], [EXIT_AT, 0.6, 0.22, 0]] });

  // 11–13 s: encerramento. Traço de acento sob a marca e composição final.
  anim('underline', { sx: [[10.9, 0.9, 0, 1, 'inOutCubic']], o: [[10.9, 0.2, 0, 1]] }, [LOGO.cx, 724]);

  // ---------- partículas (canvas) ----------
  const canvas = $('fx');
  const ctx = canvas.getContext('2d');
  let W = 0, H = 0, dpr = 1;
  const rnd = ((seed) => () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let r = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  })(7);
  const particles = Array.from({ length: 72 }, () => {
    const z = 0.25 + rnd() * 0.75;
    return { x: rnd(), y: rnd(), z, vx: (rnd() - 0.5) * 0.006, vy: -(0.004 + rnd() * 0.01) * z, ph: rnd() * 6.28, w: 0.6 + rnd() * 1.4 };
  });

  function drawParticles(t) {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    const g = ramp(t, 0.3, 1.8) * (1 - ramp(t, EXIT_AT, EXIT_AT + 0.8));
    if (g <= 0) return;
    const pull = 0.07 * ease.inOutCubic(ramp(t, 2.0, 5.5));  // convergem levemente na construção
    const unit = Math.max(W, H);
    ctx.fillStyle = '#d6e4ff';
    for (const p of particles) {
      let x = (((p.x + p.vx * t) % 1) + 1) % 1;
      let y = (((p.y + p.vy * t) % 1) + 1) % 1;
      x = (x - 0.5) * (1 - pull * p.z) + 0.5;
      y = (y - 0.5) * (1 - pull * p.z) + 0.5;
      const a = g * (0.06 + 0.34 * p.z * p.z) * (0.7 + 0.3 * Math.sin(t * p.w + p.ph));
      ctx.globalAlpha = a;
      ctx.beginPath();
      ctx.arc(x * W * dpr, y * H * dpr, (0.5 + 1.3 * p.z) * dpr * Math.min(1.4, unit / 1400 + 0.4), 0, 6.2832);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  // ---------- enquadramento responsivo ----------
  // A marca ocupa cerca de metade da largura em telas largas e mais em telas estreitas; o
  // viewBox acompanha a proporção da janela, então nada é cortado nem distorcido.
  function layout() {
    W = innerWidth; H = innerHeight; dpr = Math.min(devicePixelRatio || 1, 2);
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    const portrait = W / H < 0.9;
    const s = portrait ? Math.min((0.84 * W) / LOGO.w, (0.4 * H) / LOGO.h) : Math.min((0.5 * W) / LOGO.w, (0.46 * H) / LOGO.h);
    const vw = W / s, vh = H / s;
    svg.setAttribute('viewBox', `${r3(LOGO.cx - vw / 2)} ${r3(LOGO.cy - vh / 2)} ${r3(vw)} ${r3(vh)}`);
    glow.unit = s;  // a luz tem 1520×860 unidades do logotipo
  }

  // ---------- relógio, saída e integração ----------
  const veil = $('veil');
  const replay = $('replay');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const stats = { frames: 0, maxGap: 0, duration: DURATION };
  let start = 0, lastNow = 0, running = false, finished = false, skipFrom = null, now = 0, cur = 0;

  // As máscaras de preenchimento só existem durante a revelação; depois saem do caminho de pintura.
  const wipes = [[$('top-fill'), 'url(#m-wipe-top)'], [$('bottom-fill'), 'url(#m-wipe-bottom)']];
  let wipesOn = null;

  // Brilho da marca: desfocado uma única vez num bitmap (sombra do canvas), em vez de um filtro
  // SVG recalculado a cada quadro.
  function buildBloom() {
    const pad = 90, off = 5000, img = $('bloom');
    const c = document.createElement('canvas');
    c.width = LOGO.w + pad * 2; c.height = LOGO.h + pad * 2;
    const g = c.getContext('2d');
    g.shadowColor = '#fff'; g.shadowBlur = 34; g.shadowOffsetX = off;
    g.translate(pad - 403 - off, pad - 274);
    g.fillStyle = '#fff';
    for (const p of svg.querySelectorAll('defs path')) {
      g.fill(new Path2D(p.getAttribute('d')), p.getAttribute('fill-rule') === 'evenodd' ? 'evenodd' : 'nonzero');
    }
    img.setAttribute('href', c.toDataURL());
    img.setAttribute('x', 403 - pad); img.setAttribute('y', 274 - pad);
    img.setAttribute('width', c.width); img.setAttribute('height', c.height);
  }

  function render(t) {
    cur = t;
    const on = t < 6.3;
    if (on !== wipesOn) {
      wipesOn = on;
      for (const [node, mask] of wipes) if (on) node.setAttribute('mask', mask); else node.removeAttribute('mask');
    }
    renderActors(t);
    drawParticles(t);
  }

  // Versão para quem pede menos movimento: só a composição final, com fade de entrada e saída.
  function renderReduced(t) {
    if (!cur) render(12.6);
    cur = t;
    veil.style.opacity = r3(1 - ramp(t, 0, 0.6) + ramp(t, 2.6, 3.2));
  }

  function frame(ts) {
    if (!running) return;
    if (!start) start = ts;
    if (lastNow) { stats.maxGap = Math.max(stats.maxGap, ts - lastNow); if (stats.log) stats.log.push([+now.toFixed(2), Math.round(ts - lastNow)]); }
    lastNow = ts; stats.frames++;
    now = (ts - start) / 1000;
    const end = reduced ? 3.2 : DURATION;
    if (skipFrom !== null) {
      const k = ramp(now, skipFrom, skipFrom + 0.45);
      veil.style.opacity = Math.max(+veil.style.opacity || 0, ease.inCubic(k));
      if (k >= 1) return finish();
    } else if (reduced) {
      renderReduced(Math.min(now, end));
    } else {
      render(Math.min(now, end));
    }
    if (now >= end && skipFrom === null) return finish();
    requestAnimationFrame(frame);
  }

  function finish() {
    if (finished) return;
    finished = true; running = false;
    stats.elapsed = now;
    veil.style.opacity = 1;
    window.dispatchEvent(new CustomEvent('secada:intro-end', { detail: { skipped: skipFrom !== null } }));
    if (window.parent !== window) window.parent.postMessage({ type: 'secada:intro-end' }, '*');
    const next = params.get('next');
    if (next) {
      const url = new URL(next, location.href);
      if (url.origin === location.origin) return location.replace(url.href);
    }
    replay.hidden = false;
    requestAnimationFrame(() => replay.classList.add('show'));
  }

  function play() {
    finished = false; skipFrom = null; start = 0; lastNow = 0; cur = 0;
    stats.frames = 0; stats.maxGap = 0;
    veil.style.opacity = reduced ? 1 : 0;
    replay.classList.remove('show'); replay.hidden = true;
    for (const a of actors) a.last = {};
    if (reduced) renderReduced(0); else render(0);
    running = true;
    requestAnimationFrame(frame);
  }

  function skip() {
    if (running && skipFrom === null && now > 0.2) skipFrom = now;
  }

  function seek(t) {
    running = false;
    veil.style.opacity = 0;
    for (const a of actors) a.last = {};
    render(Math.max(0, Math.min(DURATION, t)));
  }

  addEventListener('resize', () => { layout(); for (const a of actors) a.last = {}; if (reduced) render(12.6); else render(cur); });
  addEventListener('keydown', (e) => { if (['Escape', 'Enter', ' '].includes(e.key) && running) { e.preventDefault(); skip(); } });
  $('intro').addEventListener('pointerdown', skip);
  replay.addEventListener('click', play);

  window.SecadaIntro = { play, skip, seek, duration: DURATION, stats };

  buildBloom();
  layout();
  const frozen = params.get('t');
  if (frozen !== null && !Number.isNaN(+frozen)) seek(+frozen);
  else play();
})();
