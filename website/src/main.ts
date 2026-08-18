import './styles.css';

const menuButton = document.querySelector<HTMLButtonElement>('.menu-button');
const mobileMenu = document.querySelector<HTMLElement>('.mobile-menu');
const themeButton = document.querySelector<HTMLButtonElement>('.theme-button');
const themeLabel = document.querySelector<HTMLElement>('.theme-label');

menuButton?.addEventListener('click', () => {
  const isOpen = menuButton.getAttribute('aria-expanded') === 'true';
  menuButton.setAttribute('aria-expanded', String(!isOpen));
  mobileMenu?.classList.toggle('is-open', !isOpen);
});

mobileMenu?.querySelectorAll('a').forEach((link) => {
  link.addEventListener('click', () => {
    menuButton?.setAttribute('aria-expanded', 'false');
    mobileMenu.classList.remove('is-open');
  });
});

themeButton?.addEventListener('click', () => {
  const current = document.documentElement.dataset.theme ?? 'system';
  const next = current === 'system' ? 'dark' : current === 'dark' ? 'light' : 'system';
  document.documentElement.dataset.theme = next;
  themeButton.setAttribute('aria-pressed', String(next === 'dark'));
  if (themeLabel) themeLabel.textContent = next[0].toUpperCase() + next.slice(1);
});
