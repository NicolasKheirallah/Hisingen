import Lenis from 'lenis';

export class SmoothScrollManager {
  private lenis: Lenis | null = null;
  private animId: number | null = null;

  constructor() {
    const isReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (isReducedMotion) return;

    this.init();
  }

  private init(): void {
    try {
      this.lenis = new Lenis({
        duration: 1.15,
        easing: (t: number) => Math.min(1, 1.001 - Math.pow(2, -10 * t)),
        orientation: 'vertical',
        gestureOrientation: 'vertical',
        smoothWheel: true,
        wheelMultiplier: 0.9,
        touchMultiplier: 1.5,
      });

      const raf = (time: number): void => {
        this.lenis?.raf(time);
        this.animId = requestAnimationFrame(raf);
      };
      this.animId = requestAnimationFrame(raf);

      // Handle in-page smooth anchor clicks
      document.querySelectorAll<HTMLAnchorElement>('a[href^="#"]').forEach((anchor) => {
        anchor.addEventListener('click', (e) => {
          const href = anchor.getAttribute('href');
          if (!href || href === '#' || !href.startsWith('#')) return;
          const target = document.querySelector<HTMLElement>(href);
          if (target && this.lenis) {
            e.preventDefault();
            this.lenis.scrollTo(target, { offset: -60 });
          }
        });
      });
    } catch (err) {
      console.warn('Lenis smooth scroll fallback to native:', err);
    }
  }

  public destroy(): void {
    if (this.animId) cancelAnimationFrame(this.animId);
    this.lenis?.destroy();
    this.lenis = null;
  }
}
