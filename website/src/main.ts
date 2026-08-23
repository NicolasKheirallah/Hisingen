import './styles.css';
import { ChargeCalc } from './components/ChargeCalc';
import { ChargingCurve } from './components/ChargingCurve';
import { SmoothScrollManager } from './utils/smoothScroll';
import { VehicleViewer } from './components/VehicleViewer';

document.documentElement.classList.add('js');

// Initialize Luxury Inertial Smooth Scrolling (Lenis)
new SmoothScrollManager();

// Initialize Interactive Charge Simulator & Power Curve
new ChargeCalc('charge-calc');
let chargingCurve: ChargingCurve | null = null;
if (document.getElementById('charging-curve-stage')) {
  try {
    chargingCurve = new ChargingCurve('charging-curve-stage');
    const slider = document.querySelector<HTMLInputElement>('[data-calc-slider]');
    slider?.addEventListener('input', () => {
      chargingCurve?.setSoc(Number(slider.value));
    });
  } catch (e) {
    console.warn('Charging curve init:', e);
  }
}

// Initialize Interactive Polestar 2 Studio Showcase
if (document.getElementById('vehicle-showcase')) {
  try {
    new VehicleViewer('vehicle-showcase');
  } catch (e) {
    console.warn('Vehicle showcase init:', e);
  }
}

// Lazy-load Three.js Automotive Studio Suite
let threeStudio: any = null;
const initThreeStudio = async (): Promise<void> => {
  const stage = document.getElementById('three-studio-stage');
  const wrap = document.getElementById('showcase-art-wrap');
  if (!stage || !wrap) return;

  try {
    const { ThreeVehicleStudio } = await import('./components/ThreeVehicleStudio');
    threeStudio = new ThreeVehicleStudio('three-studio-stage');
    wrap.classList.add('has-three');

    // Studio Mode Pills
    const modePills = document.querySelectorAll<HTMLButtonElement>('.studio-mode-pill');
    const captionEl = document.querySelector<HTMLElement>('[data-viewer-caption]');
    const captions: Record<string, string> = {
      orbit: '360° Studio Orbit · Drag horizontally to rotate with momentum · Midnight finish with Pixel LED headlights',
      parallax: '2.5D Optical Parallax · Move cursor to explore geometric depth and glossy clearcoat reflection sheen',
      windtunnel: 'Aerodynamic Wind Tunnel · 0.278 Cd streamline airflow simulation across the fastback silhouette',
    };

    modePills.forEach((pill) => {
      pill.addEventListener('click', () => {
        modePills.forEach((p) => {
          p.classList.remove('is-active');
          p.setAttribute('aria-pressed', 'false');
        });
        pill.classList.add('is-active');
        pill.setAttribute('aria-pressed', 'true');
        const mode = (pill.dataset.studioMode || 'orbit') as any;
        threeStudio?.setMode(mode);
        if (captionEl && captions[mode]) {
          captionEl.textContent = captions[mode];
        }
      });
    });

    // Angle Tabs connection with 3D studio
    const angleTabs = document.querySelectorAll<HTMLButtonElement>('[data-angle-tab]');
    angleTabs.forEach((tab, index) => {
      tab.addEventListener('click', () => {
        threeStudio?.setAngleIndex(index);
      });
    });
  } catch (err) {
    console.warn('Three.js studio load fallback:', err);
  }
};

// Lazy-load Three.js Metrics Field for Section 07
let metricsField: any = null;
const initMetricsField = async (): Promise<void> => {
  const stage = document.getElementById('metrics-three-stage');
  if (!stage) return;

  try {
    const { ThreeMetricsField } = await import('./components/ThreeMetricsField');
    metricsField = new ThreeMetricsField('metrics-three-stage');
  } catch (err) {
    console.warn('Metrics field Three.js init fallback:', err);
  }
};

if ('requestIdleCallback' in window) {
  (window as any).requestIdleCallback(() => {
    initThreeStudio();
    initMetricsField();
  });
} else {
  setTimeout(() => {
    initThreeStudio();
    initMetricsField();
  }, 100);
}

const themeToggle = document.querySelector<HTMLButtonElement>('#theme-toggle');
const themeMeta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
const colorSchemeQuery = window.matchMedia('(prefers-color-scheme: dark)');

type Theme = 'system' | 'light' | 'dark';

const isDark = (theme: Theme): boolean =>
  theme === 'dark' || (theme === 'system' && colorSchemeQuery.matches);

const applyThemeMeta = (theme: Theme): void => {
  const dark = isDark(theme);
  themeMeta?.setAttribute('content', dark ? '#101113' : '#f7f6f3');
  chargingCurve?.setTheme(dark);
  threeStudio?.setTheme(dark);
  metricsField?.setTheme?.(dark);
};

let stored: Theme = 'system';
try {
  const value = localStorage.getItem('hisingen-theme');
  if (value === 'light' || value === 'dark') stored = value;
} catch {
  stored = 'system';
}
if (stored !== 'system') document.documentElement.dataset.theme = stored;
if (themeToggle) {
  themeToggle.dataset.mode = stored;
  themeToggle.setAttribute(
    'aria-label',
    `Color scheme: ${stored}. Activate to switch to ${stored === 'dark' ? 'auto' : stored === 'light' ? 'dark' : 'light'}.`,
  );
}
applyThemeMeta(stored);

themeToggle?.addEventListener('click', () => {
  const next: Theme = stored === 'system' ? 'light' : stored === 'light' ? 'dark' : 'system';
  stored = next;
  if (next === 'system') {
    delete document.documentElement.dataset.theme;
    try { localStorage.removeItem('hisingen-theme'); } catch { /* session-only preference */ }
  } else {
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('hisingen-theme', next); } catch { /* session-only preference */ }
  }
  if (themeToggle) {
    themeToggle.dataset.mode = next;
    themeToggle.setAttribute(
      'aria-label',
      `Color scheme: ${next}. Activate to switch to ${next === 'dark' ? 'auto' : next === 'light' ? 'dark' : 'light'}.`,
    );
  }
  applyThemeMeta(next);
});

colorSchemeQuery.addEventListener('change', () => applyThemeMeta(document.documentElement.dataset.theme === 'dark' ? 'dark' : stored));

const header = document.querySelector<HTMLElement>('#site-header');
let scrollTicking = false;
const updateHeader = (): void => {
  header?.classList.toggle('is-scrolled', window.scrollY > 24);
  scrollTicking = false;
};
window.addEventListener('scroll', () => {
  if (!scrollTicking) {
    scrollTicking = true;
    window.requestAnimationFrame(updateHeader);
  }
}, { passive: true });
updateHeader();

const navToggle = document.querySelector<HTMLButtonElement>('#nav-toggle');
const mobileNav = document.querySelector<HTMLElement>('#mobile-nav');
const setMobileNav = (open: boolean): void => {
  if (!navToggle || !mobileNav) return;
  if (open) mobileNav.setAttribute('data-open', '');
  else mobileNav.removeAttribute('data-open');
  navToggle.setAttribute('aria-expanded', String(open));
  navToggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
};
navToggle?.addEventListener('click', () => setMobileNav(navToggle.getAttribute('aria-expanded') !== 'true'));
mobileNav?.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => setMobileNav(false)));
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && navToggle?.getAttribute('aria-expanded') === 'true') setMobileNav(false);
});

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const revealables = document.querySelectorAll<HTMLElement>('.reveal, .reveal-late');
if (reducedMotion || !('IntersectionObserver' in window)) {
  revealables.forEach((el) => el.classList.add('is-in'));
} else {
  const revealObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-in');
        revealObserver.unobserve(entry.target);
      }
    }
  }, { threshold: 0.1, rootMargin: '0px 0px -7% 0px' });
  revealables.forEach((el) => revealObserver.observe(el));
}

const modeDemo = document.querySelector<HTMLElement>('#mode-demo');
const modeValue = modeDemo?.querySelector<HTMLElement>('[data-menubar-value]');
const modeCaption = modeDemo?.querySelector<HTMLElement>('[data-mode-caption]');
const modeContent: Record<string, { value: string; caption: string }> = {
  icon: { value: '', caption: 'Icon only. The quietest option — the panel is still one click away.' },
  battery: { value: '90%', caption: 'Battery level, right where your eyes already are.' },
  range: { value: '330 km', caption: 'Estimated range, as last reported by the car.' },
  charging: { value: '11 kW', caption: 'Live charging power while the car is plugged in.' },
  locked: { value: 'Locked', caption: 'Lock state at a glance — reassurance without opening anything.' },
};
modeDemo?.querySelectorAll<HTMLButtonElement>('.mode-button').forEach((button) => {
  button.addEventListener('click', () => {
    const mode = button.dataset.mode ?? 'battery';
    if (modeDemo.dataset.mode === mode) return;
    modeDemo.dataset.mode = mode;
    if (modeValue) {
      modeValue.style.opacity = '0';
      modeValue.style.transform = 'translateY(2px)';
      setTimeout(() => {
        modeValue.textContent = modeContent[mode]?.value ?? '';
        modeValue.style.opacity = '1';
        modeValue.style.transform = 'none';
      }, 120);
    }
    if (modeCaption) modeCaption.textContent = modeContent[mode]?.caption ?? '';
    modeDemo.querySelectorAll('.mode-button').forEach((b) => {
      const active = b === button;
      b.classList.toggle('is-active', active);
      b.setAttribute('aria-pressed', String(active));
    });
  });
});

const gallery = document.querySelector<HTMLElement>('#gallery');
const galleryPrevBtn = document.querySelector<HTMLButtonElement>('#gallery-prev-btn');
const galleryNextBtn = document.querySelector<HTMLButtonElement>('#gallery-next-btn');

const scrollGallery = (direction: 'prev' | 'next'): void => {
  if (!gallery) return;
  const cardWidth = gallery.querySelector<HTMLElement>('.gallery-item:not([hidden])')?.offsetWidth ?? 300;
  const scrollAmount = cardWidth + 24;
  gallery.scrollBy({ left: direction === 'next' ? scrollAmount : -scrollAmount, behavior: 'smooth' });
};

galleryPrevBtn?.addEventListener('click', () => scrollGallery('prev'));
galleryNextBtn?.addEventListener('click', () => scrollGallery('next'));

const lightbox = document.querySelector<HTMLDialogElement>('#lightbox');
const lightboxImg = document.querySelector<HTMLImageElement>('#lightbox-img');
const lightboxCaption = document.querySelector<HTMLElement>('#lightbox-caption');
const lightboxCount = document.querySelector<HTMLElement>('#lightbox-count');
const allGalleryItems = Array.from(document.querySelectorAll<HTMLButtonElement>('.gallery-item'));
let activeGalleryItems = [...allGalleryItems];
let lightboxIndex = 0;
let lightboxOpener: HTMLElement | null = null;

const showDialog = lightbox && typeof lightbox.showModal === 'function';

const setLightbox = (index: number): void => {
  if (!lightboxImg || !lightboxCaption || activeGalleryItems.length === 0) return;
  lightboxIndex = (index + activeGalleryItems.length) % activeGalleryItems.length;
  const item = activeGalleryItems[lightboxIndex]!;
  lightboxImg.src = item.dataset.full ?? '';
  lightboxCaption.id = 'lightbox-caption';
  lightboxCaption.textContent = item.dataset.caption ?? '';
  if (lightboxCount) lightboxCount.textContent = `${lightboxIndex + 1} / ${activeGalleryItems.length}`;
};

const openLightbox = (index: number, opener: HTMLElement): void => {
  if (!lightbox || !showDialog) return;
  lightboxOpener = opener;
  setLightbox(index);
  lightbox.showModal();
};

const closeLightbox = (): void => {
  if (!lightbox || !lightbox.open) return;
  lightbox.close();
  lightboxOpener?.focus();
  lightboxOpener = null;
};

allGalleryItems.forEach((item) => {
  item.addEventListener('click', () => {
    const idx = activeGalleryItems.indexOf(item);
    if (idx !== -1) {
      openLightbox(idx, item);
    }
  });
});

// Gallery Category Filter
const galleryFilterBtns = Array.from(document.querySelectorAll<HTMLButtonElement>('.gallery-filter-btn'));
galleryFilterBtns.forEach((btn) => {
  btn.addEventListener('click', () => {
    const cat = btn.dataset.galleryFilter ?? 'all';
    galleryFilterBtns.forEach((b) => {
      const active = b === btn;
      b.classList.toggle('is-active', active);
      b.setAttribute('aria-pressed', String(active));
    });

    allGalleryItems.forEach((item) => {
      const match = cat === 'all' || item.dataset.category === cat;
      if (match) {
        item.removeAttribute('hidden');
      } else {
        item.setAttribute('hidden', '');
      }
    });

    activeGalleryItems = allGalleryItems.filter((i) => !i.hasAttribute('hidden'));
    if (gallery) {
      gallery.scrollTo({ left: 0, behavior: 'smooth' });
    }
  });
});

document.querySelector('#lightbox-close')?.addEventListener('click', closeLightbox);
document.querySelector('#lightbox-prev')?.addEventListener('click', () => setLightbox(lightboxIndex - 1));
document.querySelector('#lightbox-next')?.addEventListener('click', () => setLightbox(lightboxIndex + 1));

lightbox?.addEventListener('click', (event) => {
  if (event.target === lightbox) closeLightbox();
});

lightbox?.addEventListener('keydown', (event) => {
  if (event.key === 'ArrowLeft') { event.preventDefault(); setLightbox(lightboxIndex - 1); }
  if (event.key === 'ArrowRight') { event.preventDefault(); setLightbox(lightboxIndex + 1); }
});

let touchStartX = 0;
let touchStartY = 0;

lightbox?.addEventListener('touchstart', (e: TouchEvent) => {
  if (e.touches.length === 1) {
    touchStartX = e.touches[0]!.clientX;
    touchStartY = e.touches[0]!.clientY;
  }
}, { passive: true });

lightbox?.addEventListener('touchend', (e: TouchEvent) => {
  if (e.changedTouches.length === 1) {
    const deltaX = e.changedTouches[0]!.clientX - touchStartX;
    const deltaY = e.changedTouches[0]!.clientY - touchStartY;
    if (Math.abs(deltaX) > 40 && Math.abs(deltaX) > Math.abs(deltaY)) {
      if (deltaX > 0) setLightbox(lightboxIndex - 1);
      else setLightbox(lightboxIndex + 1);
    } else if (deltaY > 60 && Math.abs(deltaY) > Math.abs(deltaX)) {
      closeLightbox();
    }
  }
}, { passive: true });

// Install Methods Tabs
const installTabs = document.querySelectorAll<HTMLButtonElement>('.install-tab');
const installPanels = document.querySelectorAll<HTMLElement>('.install-panel');

installTabs.forEach((tab) => {
  tab.addEventListener('click', () => {
    const targetId = tab.dataset.installTab;
    if (!targetId) return;

    installTabs.forEach((t) => {
      t.classList.remove('is-active');
      t.setAttribute('aria-selected', 'false');
      t.setAttribute('tabindex', '-1');
    });
    tab.classList.add('is-active');
    tab.setAttribute('aria-selected', 'true');
    tab.removeAttribute('tabindex');

    installPanels.forEach((p) => {
      if (p.id === `panel-${targetId}`) {
        p.classList.add('is-active');
        p.hidden = false;
      } else {
        p.classList.remove('is-active');
        p.hidden = true;
      }
    });
  });
});

// Copy to Clipboard Buttons
const copyButtons = document.querySelectorAll<HTMLButtonElement>('.copy-btn');
copyButtons.forEach((btn) => {
  btn.addEventListener('click', async () => {
    const text = btn.dataset.copyText;
    if (!text) return;

    try {
      await navigator.clipboard.writeText(text);
      const label = btn.querySelector<HTMLElement>('.copy-label');
      btn.classList.add('is-copied');
      if (label) label.textContent = 'Copied!';

      setTimeout(() => {
        btn.classList.remove('is-copied');
        if (label) label.textContent = 'Copy';
      }, 2000);
    } catch {
      // Fallback if clipboard API is restricted
      const label = btn.querySelector<HTMLElement>('.copy-label');
      if (label) label.textContent = 'Copied!';
      setTimeout(() => {
        if (label) label.textContent = 'Copy';
      }, 2000);
    }
  });
});

// Settings & Feature Directory Tabs
const settingsTabs = document.querySelectorAll<HTMLButtonElement>('[data-settings-tab]');
const settingsPanels = document.querySelectorAll<HTMLElement>('.settings-panel');
settingsTabs.forEach((tab) => {
  tab.addEventListener('click', () => {
    const targetId = tab.dataset.settingsTab;
    if (!targetId) return;

    settingsTabs.forEach((t) => {
      t.classList.remove('is-active');
      t.setAttribute('aria-selected', 'false');
    });
    tab.classList.add('is-active');
    tab.setAttribute('aria-selected', 'true');

    settingsPanels.forEach((p) => {
      if (p.id === `panel-${targetId}`) {
        p.classList.add('is-active');
      } else {
        p.classList.remove('is-active');
      }
    });
  });
});

const year = document.querySelector<HTMLElement>('#year');
if (year) year.textContent = String(new Date().getFullYear());
