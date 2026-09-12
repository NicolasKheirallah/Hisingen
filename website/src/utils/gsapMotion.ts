import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import type Lenis from 'lenis';

gsap.registerPlugin(ScrollTrigger);

export class GsapMotionManager {
  private isReducedMotion: boolean;
  private progressBar: HTMLElement | null = null;

  constructor(lenis: Lenis | null) {
    this.isReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    this.initLenisSync(lenis);
    this.initScrollProgressBar();

    if (!this.isReducedMotion) {
      this.initHeroSequence();
      this.initHeroTilt();
      this.initMagneticButtons();
      this.initSectionScrollTriggers();
      this.initPrivacyFlow();
      this.initMetricsScrollTrigger();
      this.initGalleryAnimations();
    }
  }

  /**
   * Synchronize Lenis smooth scroll with GSAP ScrollTrigger ticker.
   */
  private initLenisSync(lenis: Lenis | null): void {
    if (!lenis) return;

    lenis.on('scroll', ScrollTrigger.update);

    gsap.ticker.add((time: number) => {
      lenis.raf(time * 1000);
    });

    gsap.ticker.lagSmoothing(0);
  }

  /**
   * Top ambient scroll progress indicator.
   */
  private initScrollProgressBar(): void {
    let bar = document.querySelector<HTMLElement>('.scroll-progress-bar');
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'scroll-progress-bar';
      document.body.prepend(bar);
    }
    this.progressBar = bar;

    gsap.to(this.progressBar, {
      scaleX: 1,
      ease: 'none',
      scrollTrigger: {
        trigger: document.body,
        start: 'top top',
        end: 'bottom bottom',
        scrub: 0.15,
      },
    });
  }

  /**
   * Hero entrance choreography and floating ambient levitation.
   */
  private initHeroSequence(): void {
    const hero = document.getElementById('hero');
    if (!hero) return;

    const kicker = hero.querySelector('.kicker');
    const title = hero.querySelector('.hero-title');
    const lead = hero.querySelector('.hero-lead');
    const actions = hero.querySelector('.hero-actions');
    const heroShot = hero.querySelector('.glance-preview, .shot-hero, .shot-tall');
    const badge = hero.querySelector('.hero-badge');

    const tl = gsap.timeline({ defaults: { ease: 'power3.out' } });

    if (badge) {
      tl.from(badge, { opacity: 0, y: -15, duration: 0.7 }, 0.1);
    }
    if (kicker) {
      tl.from(kicker, { opacity: 0, y: 15, duration: 0.7 }, 0.2);
    }
    if (title) {
      tl.from(title, { opacity: 0, y: 30, duration: 0.9 }, 0.3);
    }
    if (lead) {
      tl.from(lead, { opacity: 0, y: 20, duration: 0.8 }, 0.45);
    }
    if (actions) {
      tl.from(actions, { opacity: 0, y: 15, duration: 0.7 }, 0.6);
    }
    if (heroShot) {
      tl.from(heroShot, { opacity: 0, y: 40, scale: 0.96, duration: 1.1, ease: 'power2.out' }, 0.4);

      // Subtle ambient levitation loop on the hero card
      gsap.to(heroShot, {
        y: '-=6',
        duration: 3.2,
        repeat: -1,
        yoyo: true,
        ease: 'sine.inOut',
        delay: 1.5,
      });
    }
  }

  /**
   * 3D Gyroscopic & Mouse Tilt on Hero Showcase.
   */
  private initHeroTilt(): void {
    const heroCard = document.querySelector<HTMLElement>('#hero .shot-tall, #hero .shot-hero');
    const heroSection = document.getElementById('hero');
    if (!heroCard || !heroSection) return;

    heroCard.style.transformStyle = 'preserve-3d';
    heroCard.style.willChange = 'transform';

    const setRotateX = gsap.quickTo(heroCard, 'rotationX', { duration: 0.6, ease: 'power2.out' });
    const setRotateY = gsap.quickTo(heroCard, 'rotationY', { duration: 0.6, ease: 'power2.out' });

    const handlePointerMove = (e: PointerEvent): void => {
      const rect = heroSection.getBoundingClientRect();
      const x = (e.clientX - rect.left) / rect.width - 0.5;
      const y = (e.clientY - rect.top) / rect.height - 0.5;

      setRotateY(x * 12);
      setRotateX(-y * 12);
    };

    const handlePointerLeave = (): void => {
      setRotateX(0);
      setRotateY(0);
    };

    heroSection.addEventListener('pointermove', handlePointerMove);
    heroSection.addEventListener('pointerleave', handlePointerLeave);
  }

  /**
   * Magnetic Button Hover Physics for primary CTA buttons.
   */
  private initMagneticButtons(): void {
    const buttons = document.querySelectorAll<HTMLElement>('.hero-actions .button-primary, .download-card');
    buttons.forEach((btn) => {
      const setX = gsap.quickTo(btn, 'x', { duration: 0.4, ease: 'power2.out' });
      const setY = gsap.quickTo(btn, 'y', { duration: 0.4, ease: 'power2.out' });

      btn.addEventListener('mousemove', (e: MouseEvent) => {
        const rect = btn.getBoundingClientRect();
        const relX = e.clientX - rect.left - rect.width / 2;
        const relY = e.clientY - rect.top - rect.height / 2;
        setX(relX * 0.25);
        setY(relY * 0.25);
      });

      btn.addEventListener('mouseleave', () => {
        setX(0);
        setY(0);
      });
    });
  }

  /**
   * Staggered ScrollTriggers across architectural sections.
   */
  private initSectionScrollTriggers(): void {
    // 03 · Why Hisingen 9-Card Editorial Grid
    const whyItems = gsap.utils.toArray<HTMLElement>('.why-grid .why-item');
    if (whyItems.length > 0) {
      gsap.from(whyItems, {
        opacity: 0,
        y: 35,
        duration: 0.75,
        stagger: 0.07,
        ease: 'power2.out',
        scrollTrigger: {
          trigger: '.why-grid',
          start: 'top 82%',
          toggleActions: 'play none none none',
        },
      });
    }

    // 06 · Compact 5-Screen Directory Cards
    const screenCards = gsap.utils.toArray<HTMLElement>('.settings-feature-grid .panel-screen-card');
    if (screenCards.length > 0) {
      gsap.from(screenCards, {
        opacity: 0,
        y: 25,
        scale: 0.98,
        duration: 0.65,
        stagger: 0.05,
        ease: 'power2.out',
        scrollTrigger: {
          trigger: '.settings-feature-grid',
          start: 'top 85%',
          toggleActions: 'play none none none',
        },
      });
    }

    // 07 · Native Architecture Specs List
    const nativeListItems = gsap.utils.toArray<HTMLElement>('.native-list div');
    if (nativeListItems.length > 0) {
      gsap.from(nativeListItems, {
        opacity: 0,
        x: -20,
        duration: 0.6,
        stagger: 0.06,
        ease: 'power2.out',
        scrollTrigger: {
          trigger: '.native-list',
          start: 'top 82%',
          toggleActions: 'play none none none',
        },
      });
    }

    // Section Figures & Shots Parallax Lift
    const shots = gsap.utils.toArray<HTMLElement>('.section:not(#hero) .shot');
    shots.forEach((shot) => {
      gsap.from(shot, {
        opacity: 0,
        y: 40,
        scale: 0.97,
        duration: 0.85,
        ease: 'power2.out',
        scrollTrigger: {
          trigger: shot,
          start: 'top 85%',
          toggleActions: 'play none none none',
        },
      });
    });
  }

  /**
   * Cryptographic Direct PKCE Pulse & Flow Animation in Section 08 Privacy.
   */
  private initPrivacyFlow(): void {
    const diagram = document.querySelector<HTMLElement>('#privacy .diagram');
    if (!diagram) return;

    const macNode = diagram.querySelector<HTMLElement>('.diagram-mac');
    const providerNodes = gsap.utils.toArray<HTMLElement>('.diagram-providers .diagram-node');
    const linksLine = diagram.querySelector<HTMLElement>('.diagram-links');

    const tl = gsap.timeline({
      scrollTrigger: {
        trigger: diagram,
        start: 'top 80%',
        toggleActions: 'play none none none',
      },
    });

    if (macNode) {
      tl.from(macNode, { opacity: 0, x: -30, duration: 0.7, ease: 'power2.out' }, 0);
    }
    if (linksLine) {
      tl.from(linksLine, { scaleX: 0, transformOrigin: 'left center', duration: 0.8, ease: 'power2.inOut' }, 0.2);
    }
    if (providerNodes.length > 0) {
      tl.from(providerNodes, { opacity: 0, x: 30, duration: 0.7, stagger: 0.15, ease: 'power2.out' }, 0.4);
    }
  }

  /**
   * Metric Cards Sequential Stagger in Section 07.
   */
  private initMetricsScrollTrigger(): void {
    const metricCards = gsap.utils.toArray<HTMLElement>('.metrics-grid .metric-card');
    if (metricCards.length === 0) return;

    gsap.from(metricCards, {
      opacity: 0,
      y: 20,
      scale: 0.97,
      duration: 0.55,
      stagger: 0.04,
      ease: 'power2.out',
      scrollTrigger: {
        trigger: '.metrics-grid',
        start: 'top 85%',
        toggleActions: 'play none none none',
      },
    });
  }

  /**
   * Smooth Stagger Transitions for the 31-Screenshot Gallery.
   */
  private initGalleryAnimations(): void {
    const galleryItems = gsap.utils.toArray<HTMLElement>('.gallery-grid .gallery-item');
    if (galleryItems.length === 0) return;

    gsap.from(galleryItems, {
      opacity: 0,
      y: 30,
      scale: 0.95,
      duration: 0.65,
      stagger: 0.03,
      ease: 'power2.out',
      scrollTrigger: {
        trigger: '.gallery-grid',
        start: 'top 82%',
        toggleActions: 'play none none none',
      },
    });
  }

  /**
   * Helper to trigger smooth staggered animation when gallery filters change.
   */
  public animateGalleryFilterChange(visibleItems: HTMLElement[]): void {
    if (this.isReducedMotion) return;

    gsap.fromTo(
      visibleItems,
      { opacity: 0, y: 15, scale: 0.97 },
      {
        opacity: 1,
        y: 0,
        scale: 1,
        duration: 0.45,
        stagger: 0.025,
        ease: 'power2.out',
        overwrite: 'auto',
      }
    );
  }

  /**
   * Lightbox Modal GSAP Zoom Animation.
   */
  public static animateLightboxOpen(imgEl: HTMLElement): void {
    gsap.fromTo(
      imgEl,
      { scale: 0.92, opacity: 0, y: 20 },
      { scale: 1, opacity: 1, y: 0, duration: 0.35, ease: 'power3.out' }
    );
  }

  /**
   * Utility for smooth numeric counter animation.
   */
  public static animateNumber(
    el: HTMLElement,
    targetValue: number,
    options: {
      duration?: number;
      decimals?: number;
      prefix?: string;
      suffix?: string;
      ease?: string;
    } = {}
  ): gsap.core.Tween {
    const { duration = 0.6, decimals = 0, prefix = '', suffix = '', ease = 'power2.out' } = options;

    const currentText = el.textContent || '0';
    const cleanCurrent = parseFloat(currentText.replace(/[^0-9.-]+/g, '')) || 0;

    const obj = { val: cleanCurrent };

    return gsap.to(obj, {
      val: targetValue,
      duration,
      ease,
      onUpdate: () => {
        el.textContent = `${prefix}${obj.val.toFixed(decimals)}${suffix}`;
      },
    });
  }
}

