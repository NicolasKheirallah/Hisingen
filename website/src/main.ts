import './styles.css';

document.documentElement.classList.add('js');

const menuButton = document.querySelector<HTMLButtonElement>('.menu-button');
const mobileMenu = document.querySelector<HTMLElement>('.mobile-menu');
const themeButton = document.querySelector<HTMLButtonElement>('.theme-button');
const themeLabel = document.querySelector<HTMLElement>('.theme-label');
let storedTheme: string | null = null;
try {
  storedTheme = localStorage.getItem('hisingen-theme');
} catch {
  // Private browsing and hardened storage settings should not block the page.
}
const themeMeta = document.querySelector('meta[name="theme-color"]');
const colorSchemeQuery = window.matchMedia('(prefers-color-scheme: dark)');

if (storedTheme === 'light' || storedTheme === 'dark') {
  document.documentElement.dataset.theme = storedTheme;
  if (themeLabel) themeLabel.textContent = storedTheme[0].toUpperCase() + storedTheme.slice(1);
}

themeMeta?.setAttribute('content', storedTheme === 'dark' || (!storedTheme && colorSchemeQuery.matches) ? '#0b191e' : '#f2efe8');

const setMenu = (open: boolean): void => {
  if (!menuButton || !mobileMenu) return;
  menuButton.setAttribute('aria-expanded', String(open));
  menuButton.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
  mobileMenu.hidden = !open;
  mobileMenu.classList.toggle('is-open', open);
  if (!open && document.activeElement instanceof HTMLElement && mobileMenu.contains(document.activeElement)) {
    menuButton.focus();
  }
};

setMenu(false);

menuButton?.addEventListener('click', () => {
  const isOpen = menuButton.getAttribute('aria-expanded') === 'true';
  setMenu(!isOpen);
});

mobileMenu?.querySelectorAll('a').forEach((link) => {
  link.addEventListener('click', () => {
    setMenu(false);
  });
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') setMenu(false);
});

themeButton?.addEventListener('click', () => {
  const current = document.documentElement.dataset.theme ?? 'system';
  const next = current === 'system' ? 'dark' : current === 'dark' ? 'light' : 'system';
  if (next === 'system') {
    delete document.documentElement.dataset.theme;
    try {
      localStorage.removeItem('hisingen-theme');
    } catch {
      // Appearance still changes for the current page.
    }
  } else {
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem('hisingen-theme', next);
    } catch {
      // Appearance still changes for the current page.
    }
  }
  if (themeLabel) themeLabel.textContent = next[0].toUpperCase() + next.slice(1);
  themeButton.setAttribute('aria-label', `Appearance: ${next}. Activate to change appearance.`);
  themeMeta?.setAttribute('content', next === 'dark' || (next === 'system' && colorSchemeQuery.matches) ? '#0b191e' : '#f2efe8');
});

colorSchemeQuery.addEventListener('change', ({ matches }) => {
  if (!document.documentElement.dataset.theme) {
    themeMeta?.setAttribute('content', matches ? '#0b191e' : '#f2efe8');
  }
});
