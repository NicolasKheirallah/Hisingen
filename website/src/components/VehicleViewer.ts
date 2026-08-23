/**
 * @file VehicleViewer.ts
 * @description Interactive multi-angle vehicle showcase presenting authentic studio imagery
 */

export interface VehicleAngle {
  id: string;
  label: string;
  src: string;
  alt: string;
  caption: string;
  isSvg?: boolean;
}

const baseUrl = (import.meta.env?.BASE_URL || '/').replace(/\/$/, '') + '/';

export const POLESTAR_ANGLES: VehicleAngle[] = [
  {
    id: 'front-threequarter',
    label: '3/4 Front',
    src: `${baseUrl}assets/vehicle/polestar2-front-threequarter.webp`,
    alt: 'Polestar 2 Fastback Dual Motor official studio 3/4 front view.',
    caption: 'Front 3/4 · Midnight finish with 19" 5-V Spoke diamond cut alloys and Pixel LED headlights',
  },
  {
    id: 'front',
    label: 'Front',
    src: `${baseUrl}assets/vehicle/polestar2-front.webp`,
    alt: 'Polestar 2 Fastback Dual Motor direct front view.',
    caption: 'Direct Front · Signature Thor\'s Hammer pixel LED light signature and SmartZone sensor cluster',
  },
  {
    id: 'side',
    label: 'Side Profile',
    src: `${baseUrl}assets/vehicle/polestar2-side-profile.webp`,
    alt: 'Polestar 2 Fastback Dual Motor official studio side profile.',
    caption: 'Side profile · 4,606 mm length, 1,479 mm height, 0.278 Cd aerodynamic drag coefficient',
  },
  {
    id: 'rear-threequarter',
    label: '3/4 Rear',
    src: `${baseUrl}assets/vehicle/polestar2-rear-threequarter.webp`,
    alt: 'Polestar 2 Fastback Dual Motor official studio 3/4 rear view.',
    caption: 'Rear 3/4 · Full-width 288-LED light blade with smart adaptive illumination',
  },
  {
    id: 'rear',
    label: 'Direct Rear',
    src: `${baseUrl}assets/vehicle/polestar2-rear.webp`,
    alt: 'Polestar 2 Fastback Dual Motor direct rear view.',
    caption: 'Rear silhouette · Aerodynamic fastback tailgate and integrated rear diffuser',
  },
  {
    id: 'overhead',
    label: 'Overhead 3/4',
    src: `${baseUrl}assets/vehicle/polestar2-overhead.webp`,
    alt: 'Polestar 2 Fastback Dual Motor elevated high-angle studio view.',
    caption: 'Elevated Studio View · Panoramic tinted glass roof with illuminated Polestar symbol projection',
  },
  {
    id: 'interior',
    label: 'Interior Cockpit',
    src: `${baseUrl}assets/vehicle/polestar2-interior.webp`,
    alt: 'Polestar 2 Scandinavian minimalist interior cabin and digital instrument cluster.',
    caption: 'Interior cabin · 11.2" Android Automotive center display and 12.3" digital driver display',
  },
  {
    id: 'blueprint',
    label: 'CAD Wireframe',
    src: `${baseUrl}assets/vehicle/polestar_outline.svg`,
    alt: 'Side-profile technical line drawing blueprint of a Polestar 2.',
    caption: 'Reference blueprint · Hisingen dynamically adapts remote capabilities per model year and software level',
    isSvg: true,
  },
];

export class VehicleViewer {
  private container: HTMLElement;
  private imageEl: HTMLImageElement;
  private captionEl: HTMLElement;
  private tabs: HTMLButtonElement[] = [];
  private activeIndex = 0;

  constructor(containerId: string) {
    const container = document.getElementById(containerId);
    if (!container) throw new Error(`Container #${containerId} not found`);
    this.container = container;

    const img = this.container.querySelector<HTMLImageElement>('[data-viewer-img]');
    const caption = this.container.querySelector<HTMLElement>('[data-viewer-caption]');
    if (!img || !caption) throw new Error('Missing viewer img or caption elements');
    this.imageEl = img;
    this.captionEl = caption;

    this.initTabs();
    this.preloadImages();
  }

  private initTabs(): void {
    this.tabs = Array.from(this.container.querySelectorAll<HTMLButtonElement>('[data-angle-tab]'));
    this.tabs.forEach((tab, index) => {
      tab.addEventListener('click', () => this.selectAngle(index));
      tab.addEventListener('keydown', (e) => {
        if (e.key === 'ArrowRight') {
          const next = (index + 1) % this.tabs.length;
          this.tabs[next].focus();
          this.selectAngle(next);
        } else if (e.key === 'ArrowLeft') {
          const prev = (index - 1 + this.tabs.length) % this.tabs.length;
          this.tabs[prev].focus();
          this.selectAngle(prev);
        }
      });
    });
  }

  private preloadImages(): void {
    POLESTAR_ANGLES.forEach((angle) => {
      if (!angle.isSvg) {
        const pre = new Image();
        pre.src = angle.src;
      }
    });
  }

  public selectAngle(index: number): void {
    if (index < 0 || index >= POLESTAR_ANGLES.length) return;
    this.activeIndex = index;
    const angle = POLESTAR_ANGLES[index];

    this.tabs.forEach((tab, i) => {
      const isActive = i === index;
      tab.classList.toggle('is-active', isActive);
      tab.setAttribute('aria-selected', isActive ? 'true' : 'false');
      tab.tabIndex = isActive ? 0 : -1;
    });

    // Smooth transition
    this.imageEl.style.opacity = '0.3';
    setTimeout(() => {
      this.imageEl.src = angle.src;
      this.imageEl.alt = angle.alt;
      if (angle.isSvg) {
        this.imageEl.classList.add('is-blueprint');
      } else {
        this.imageEl.classList.remove('is-blueprint');
      }
      this.imageEl.style.opacity = '1';
    }, 120);

    this.captionEl.textContent = angle.caption;
  }

  public getActiveIndex(): number {
    return this.activeIndex;
  }
}
