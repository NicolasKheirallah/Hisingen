import './styles.css';

document.documentElement.classList.add('js');

const themeToggle = document.querySelector<HTMLButtonElement>('#theme-toggle');
const themeLabel = themeToggle?.querySelector<HTMLElement>('.theme-label');
const themeMeta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
const colorSchemeQuery = window.matchMedia('(prefers-color-scheme: dark)');

type Theme = 'system' | 'light' | 'dark';

const applyThemeMeta = (theme: Theme): void => {
  const dark = theme === 'dark' || (theme === 'system' && colorSchemeQuery.matches);
  themeMeta?.setAttribute('content', dark ? '#121412' : '#f4f3f0');
};

let stored: Theme = 'system';
try {
  const value = localStorage.getItem('hisingen-theme');
  if (value === 'light' || value === 'dark') stored = value;
} catch {
  stored = 'system';
}
if (stored !== 'system') document.documentElement.dataset.theme = stored;
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
  const label = next === 'system' ? 'Auto' : next === 'light' ? 'Light' : 'Dark';
  if (themeLabel) themeLabel.textContent = label;
  themeToggle.setAttribute('aria-label', `Color scheme: ${label}. Activate to switch to ${next === 'system' ? 'light' : next === 'light' ? 'dark' : 'auto'}.`);
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
const revealables = document.querySelectorAll<HTMLElement>('.reveal');
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
  }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });
  revealables.forEach((el) => revealObserver.observe(el));
}

const modeDemo = document.querySelector<HTMLElement>('#mode-demo');
const modeValue = modeDemo?.querySelector<HTMLElement>('[data-menubar-value]');
const modeCaption = modeDemo?.querySelector<HTMLElement>('[data-mode-caption]');
const modeContent: Record<string, { value: string; caption: string }> = {
  icon: { value: '90%', caption: 'Icon only. The quietest option — the panel is still one click away.' },
  battery: { value: '90%', caption: 'Battery level, right where your eyes already are.' },
  range: { value: '330 km', caption: 'Estimated range, as last reported by the car.' },
  charging: { value: '11 kW', caption: 'Live charging power while the car is plugged in.' },
  locked: { value: 'Locked', caption: 'Lock state at a glance — reassurance without opening anything.' },
};
modeDemo?.querySelectorAll<HTMLButtonElement>('.mode-button').forEach((button) => {
  button.addEventListener('click', () => {
    const mode = button.dataset.mode ?? 'battery';
    modeDemo.dataset.mode = mode;
    if (modeValue) modeValue.textContent = modeContent[mode]?.value ?? '90%';
    if (modeCaption) modeCaption.textContent = modeContent[mode]?.caption ?? '';
    modeDemo.querySelectorAll('.mode-button').forEach((b) => {
      const active = b === button;
      b.classList.toggle('is-active', active);
      b.setAttribute('aria-pressed', String(active));
    });
  });
});

const lightbox = document.querySelector<HTMLDialogElement>('#lightbox');
const lightboxImg = document.querySelector<HTMLImageElement>('#lightbox-img');
const lightboxCaption = document.querySelector<HTMLElement>('#lightbox-caption');
const galleryItems = Array.from(document.querySelectorAll<HTMLButtonElement>('.gallery-item'));
let lightboxIndex = 0;
let lightboxOpener: HTMLElement | null = null;

const showDialog = lightbox && typeof lightbox.showModal === 'function';

const setLightbox = (index: number): void => {
  if (!lightboxImg || !lightboxCaption || galleryItems.length === 0) return;
  lightboxIndex = (index + galleryItems.length) % galleryItems.length;
  const item = galleryItems[lightboxIndex]!;
  lightboxImg.src = item.dataset.full ?? '';
  lightboxCaption.id = 'lightbox-caption';
  lightboxCaption.textContent = item.dataset.caption ?? '';
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

galleryItems.forEach((item, index) => {
  item.addEventListener('click', () => openLightbox(index, item));
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

const year = document.querySelector<HTMLElement>('#year');
if (year) year.textContent = String(new Date().getFullYear());
