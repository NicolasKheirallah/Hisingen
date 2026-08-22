import './styles.css';

document.documentElement.classList.add('js');

const menuButton = document.querySelector<HTMLButtonElement>('.menu-button');
const mobileMenu = document.querySelector<HTMLElement>('.mobile-menu');
const themeButton = document.querySelector<HTMLButtonElement>('.theme-button');
const themeLabel = document.querySelector<HTMLElement>('.theme-label');
const themeMeta = document.querySelector('meta[name="theme-color"]');
const colorSchemeQuery = window.matchMedia('(prefers-color-scheme: dark)');

const setThemeMeta = (theme: string | null): void => {
  themeMeta?.setAttribute('content', theme === 'dark' || (!theme && colorSchemeQuery.matches) ? '#15221f' : '#f4f5f1');
};

let storedTheme: string | null = null;
try { storedTheme = localStorage.getItem('hisingen-theme'); } catch { /* Continue with system appearance. */ }
if (storedTheme === 'light' || storedTheme === 'dark') document.documentElement.dataset.theme = storedTheme;
if (themeLabel) themeLabel.textContent = storedTheme ? storedTheme[0].toUpperCase() + storedTheme.slice(1) : 'System';
setThemeMeta(storedTheme);

const setMenu = (open: boolean): void => {
  if (!menuButton || !mobileMenu) return;
  menuButton.setAttribute('aria-expanded', String(open));
  menuButton.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
  mobileMenu.hidden = !open;
  mobileMenu.classList.toggle('is-open', open);
  if (!open && mobileMenu.contains(document.activeElement)) menuButton.focus();
};
setMenu(false);
menuButton?.addEventListener('click', () => setMenu(menuButton.getAttribute('aria-expanded') !== 'true'));
mobileMenu?.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => setMenu(false)));
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') setMenu(false); });

themeButton?.addEventListener('click', () => {
  const current = document.documentElement.dataset.theme ?? 'system';
  const next = current === 'system' ? 'dark' : current === 'dark' ? 'light' : 'system';
  if (next === 'system') { delete document.documentElement.dataset.theme; try { localStorage.removeItem('hisingen-theme'); } catch { /* Appearance still changes for this page. */ } }
  else { document.documentElement.dataset.theme = next; try { localStorage.setItem('hisingen-theme', next); } catch { /* Appearance still changes for this page. */ } }
  if (themeLabel) themeLabel.textContent = next[0].toUpperCase() + next.slice(1);
  themeButton.setAttribute('aria-label', `Appearance: ${next}. Activate to change appearance.`);
  setThemeMeta(next === 'system' ? null : next);
});
colorSchemeQuery.addEventListener('change', () => { if (!document.documentElement.dataset.theme) setThemeMeta(null); });
