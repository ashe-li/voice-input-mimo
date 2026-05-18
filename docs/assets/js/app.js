// Voice Input MiMo · landing page progressive enhancements
(() => {
  // Top bar scroll state
  const topbar = document.querySelector('.topbar');
  if (topbar) {
    const onScroll = () => topbar.classList.toggle('is-scrolled', window.scrollY > 8);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  // Reveal-on-scroll (opt-in only after user has scrolled; content visible by default)
  const revealTargets = document.querySelectorAll(
    '.section-head, .loop-item, .mode-card, .split, .shortcut-card, .dl-card, .dep-note, .hero-copy, .hero-stage'
  );
  revealTargets.forEach((el) => el.classList.add('reveal', 'is-visible'));

  const prefersReduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (prefersReduced || !('IntersectionObserver' in window)) return;

  // Only opt into the fade animation if the user actually scrolls AND elements are below the fold.
  let armed = false;
  const arm = () => {
    if (armed) return;
    armed = true;
    document.documentElement.classList.add('js-ready');
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-visible');
            io.unobserve(entry.target);
          }
        }
      },
      { rootMargin: '0px 0px -8% 0px', threshold: 0 }
    );
    revealTargets.forEach((el) => {
      const rect = el.getBoundingClientRect();
      if (rect.top > window.innerHeight) {
        el.classList.remove('is-visible');
        io.observe(el);
      }
    });
    window.removeEventListener('scroll', arm);
  };
  window.addEventListener('scroll', arm, { passive: true });

  // Smooth anchor offset for the sticky top bar
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a[href^="#"]');
    if (!a) return;
    const id = a.getAttribute('href');
    if (id.length < 2) return;
    const target = document.querySelector(id);
    if (!target) return;
    e.preventDefault();
    const top = target.getBoundingClientRect().top + window.scrollY - 72;
    window.scrollTo({ top, behavior: 'smooth' });
    history.replaceState(null, '', id);
  });
})();
