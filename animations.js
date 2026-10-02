(function () {
  function animateNumber(el, duration = 1200) {
    const original = el.textContent.trim();
    const numeric = parseInt(original.replace(/[^0-9]/g, ''), 10);
    if (!numeric || numeric === 0) return;

    const suffix = original.replace(/[0-9\s\.,]+/g, '') || '';
    const start = 0;
    const startTime = performance.now();

    function frame(now) {
      const progress = Math.min((now - startTime) / duration, 1);
      const value = Math.floor(start + (numeric - start) * progress);
      el.textContent = value.toLocaleString('fr-FR') + suffix;
      if (progress < 1) requestAnimationFrame(frame);
      else el.textContent = original; // ensure final exact text
    }

    requestAnimationFrame(frame);
  }

  // Reveal-based number animation for stat blocks
  function initStatReveal() {
    const items = document.querySelectorAll('.stat-item h3');
    if (!items.length) return;

    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting && !entry.target.dataset.animated) {
          animateNumber(entry.target);
          entry.target.dataset.animated = '1';
        }
      });
    }, { threshold: 0.4 });

    items.forEach((el) => io.observe(el));
  }

  // Admin counters: animate when values change (MutationObserver)
  function initAdminCounters() {
    const ids = ['totalRdv', 'nouveauxRdv', 'traitesRdv', 'villeCount'];
    ids.forEach((id) => {
      const el = document.getElementById(id);
      if (!el) return;

      // If already non-zero, animate once
      if (/[1-9]/.test(el.textContent) && !el.dataset.animated) {
        animateNumber(el);
        el.dataset.animated = '1';
      }

      const mo = new MutationObserver(() => {
        if (!el.dataset.animated && /[1-9]/.test(el.textContent)) {
          animateNumber(el);
          el.dataset.animated = '1';
        }
      });
      mo.observe(el, { childList: true, characterData: true, subtree: true });
    });
  }

  document.addEventListener('DOMContentLoaded', () => {
    try {
      initStatReveal();
      initAdminCounters();
    } catch (e) {
      // Fail silently — animations are progressive enhancements
      console.error('Animations init error:', e);
    }
  });
})();
