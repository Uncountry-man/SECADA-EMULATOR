// Melhorias progressivas: o site funciona sem este arquivo.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  // Menu móvel
  const btn = $('.menu-btn');
  const nav = $('#nav');
  if (btn && nav) {
    const set = (open) => {
      nav.classList.toggle('open', open);
      btn.setAttribute('aria-expanded', String(open));
      btn.setAttribute('aria-label', open ? 'Fechar menu' : 'Abrir menu');
    };
    btn.addEventListener('click', () => set(!nav.classList.contains('open')));
    nav.addEventListener('click', (e) => e.target.closest('a') && set(false));
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && nav.classList.contains('open')) { set(false); btn.focus(); }
    });
  }

  // Copiar para a área de transferência, com retorno visual e anúncio para leitores de tela
  const live = $('#live');
  const fallbackCopy = (text) => {
    const t = Object.assign(document.createElement('textarea'), { value: text });
    t.style.cssText = 'position:fixed;opacity:0';
    document.body.append(t); t.select();
    const ok = document.execCommand('copy'); t.remove(); return ok;
  };
  $$('[data-copy]').forEach((b) => {
    const label = $('.copy-label', b);
    b.addEventListener('click', async () => {
      const text = b.dataset.copy;
      let ok = false;
      try { await navigator.clipboard.writeText(text); ok = true; } catch { ok = fallbackCopy(text); }
      b.classList.toggle('done', ok);
      if (label) label.textContent = ok ? 'Copiado' : 'Falhou';
      if (live) live.textContent = ok ? 'Copiado para a área de transferência' : 'Não foi possível copiar';
      setTimeout(() => { b.classList.remove('done'); if (label) label.textContent = 'Copiar'; }, 1800);
    });
  });

  // Aviso quando o visitante não está num Linux x86-64
  const warn = $('#platform-warning');
  if (warn) {
    const ua = navigator.userAgent;
    const plat = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || '';
    const isLinux = /Linux/i.test(plat) || (/Linux/.test(ua) && !/Android/.test(ua));
    const isArm = /aarch64|arm/i.test(plat) || /aarch64|armv8/i.test(ua);
    let msg = '';
    if (/Android/.test(ua)) msg = 'Você parece estar num aparelho Android.';
    else if (!isLinux) msg = 'Você parece estar usando ' + (/Win/i.test(plat + ua) ? 'Windows' : /Mac/i.test(plat + ua) ? 'macOS' : 'um sistema que não é Linux') + '.';
    else if (isArm) msg = 'Seu processador parece ser ARM.';
    if (msg) {
      $('#platform-msg', warn).textContent = msg;
      warn.hidden = false;
    }
  }

  // Link ativo na navegação conforme a seção visível
  const spy = (links, getTarget) => {
    const map = new Map();
    links.forEach((a) => { const t = getTarget(a); if (t) map.set(t, a); });
    if (!map.size || !('IntersectionObserver' in window)) return;
    const io = new IntersectionObserver((entries) => {
      entries.forEach((en) => {
        if (!en.isIntersecting) return;
        links.forEach((a) => a.removeAttribute('aria-current'));
        map.get(en.target).setAttribute('aria-current', 'true');
      });
    }, { rootMargin: '-45% 0px -50% 0px' });
    map.forEach((_, t) => io.observe(t));
  };
  spy($$('#nav a[href^="#"]'), (a) => document.getElementById(a.getAttribute('href').slice(1)));
  spy($$('.toc a'), (a) => document.getElementById(a.getAttribute('href').slice(1)));
})();
