/**
 * @file ChargingCurve.ts
 * @description Interactive Canvas-rendered battery telemetry and 205 kW DC fast-charging curve
 */

export class ChargingCurve {
  private container: HTMLElement;
  private canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private tooltipEl: HTMLElement | null = null;
  private currentSoc = 80;
  private isHovered = false;
  private hoverSoc = 80;
  private isDark = false;

  constructor(containerId: string) {
    const container = document.getElementById(containerId);
    if (!container) throw new Error(`Container #${containerId} not found`);
    this.container = container;

    this.canvas = document.createElement('canvas');
    this.canvas.className = 'charging-curve-canvas';
    this.container.appendChild(this.canvas);

    const context = this.canvas.getContext('2d');
    if (!context) throw new Error('2D Canvas Context not supported');
    this.ctx = context;

    this.tooltipEl = document.querySelector<HTMLElement>('[data-curve-tooltip]');
    this.isDark = document.documentElement.dataset.theme === 'dark' ||
      (!document.documentElement.dataset.theme && window.matchMedia('(prefers-color-scheme: dark)').matches);

    this.init();
    this.bindEvents();
    this.draw();
  }

  private init(): void {
    this.resize();
  }

  private resize(): void {
    const rect = this.container.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const width = rect.width || 340;
    const height = 130;

    this.canvas.width = width * dpr;
    this.canvas.height = height * dpr;
    this.canvas.style.width = `${width}px`;
    this.canvas.style.height = `${height}px`;

    this.ctx.setTransform(1, 0, 0, 1, 0, 0);
    this.ctx.scale(dpr, dpr);
  }

  private getPowerAtSoc(soc: number): number {
    // Polestar 2 78 kWh DC 205 kW fast charging curve
    if (soc < 10) return 130 + (soc / 10) * 75; // ramp up
    if (soc <= 30) return 205; // peak flat plateau
    if (soc <= 50) return 205 - ((soc - 30) / 20) * 55; // 205 -> 150 kW
    if (soc <= 70) return 150 - ((soc - 50) / 20) * 50; // 150 -> 100 kW
    if (soc <= 85) return 100 - ((soc - 70) / 15) * 55; // 100 -> 45 kW
    return Math.max(12, 45 - ((soc - 85) / 15) * 33); // trickle 45 -> 12 kW
  }

  public setSoc(soc: number): void {
    this.currentSoc = Math.max(0, Math.min(100, soc));
    this.draw();
  }

  public setTheme(isDark: boolean): void {
    this.isDark = isDark;
    this.draw();
  }

  private bindEvents(): void {
    window.addEventListener('resize', () => {
      this.resize();
      this.draw();
    }, { passive: true });

    const handlePointer = (e: PointerEvent): void => {
      const rect = this.canvas.getBoundingClientRect();
      const x = Math.max(0, Math.min(rect.width, e.clientX - rect.left));
      const padLeft = 32;
      const padRight = 16;
      const plotWidth = rect.width - padLeft - padRight;
      const norm = Math.max(0, Math.min(1, (x - padLeft) / plotWidth));
      this.hoverSoc = Math.round(norm * 100);
      this.isHovered = true;
      this.draw();
      this.updateTooltip();
    };

    this.canvas.addEventListener('pointermove', handlePointer, { passive: true });
    this.canvas.addEventListener('pointerenter', handlePointer, { passive: true });
    this.canvas.addEventListener('pointerleave', () => {
      this.isHovered = false;
      this.draw();
      if (this.tooltipEl) this.tooltipEl.style.opacity = '0';
    });
  }

  private updateTooltip(): void {
    if (!this.tooltipEl) return;
    const power = Math.round(this.getPowerAtSoc(this.hoverSoc));
    const voltage = Math.round(350 + (this.hoverSoc / 100) * 50);
    this.tooltipEl.innerHTML = `<strong>${this.hoverSoc}% SoC</strong> · <span>${power} kW</span> (${voltage}V)`;
    this.tooltipEl.style.opacity = '1';
  }

  public draw(): void {
    const width = parseFloat(this.canvas.style.width) || 340;
    const height = parseFloat(this.canvas.style.height) || 130;
    const pad = { top: 12, right: 16, bottom: 24, left: 34 };
    const plotW = width - pad.left - pad.right;
    const plotH = height - pad.top - pad.bottom;

    this.ctx.clearRect(0, 0, width, height);

    // Background sweet-spot zone (10% to 80% SoC)
    const x10 = pad.left + 0.1 * plotW;
    const x80 = pad.left + 0.8 * plotW;
    this.ctx.fillStyle = this.isDark ? 'rgba(216, 159, 95, 0.05)' : 'rgba(216, 159, 95, 0.08)';
    this.ctx.fillRect(x10, pad.top, x80 - x10, plotH);

    // Subtle grid lines & axes
    this.ctx.strokeStyle = this.isDark ? 'rgba(255, 255, 255, 0.07)' : 'rgba(0, 0, 0, 0.07)';
    this.ctx.lineWidth = 1;
    this.ctx.fillStyle = this.isDark ? '#8d9095' : '#72767a';
    this.ctx.font = '9px "JetBrains Mono", monospace';
    this.ctx.textAlign = 'right';
    this.ctx.textBaseline = 'middle';

    // Y ticks: 200 kW, 100 kW, 0 kW
    [200, 100, 0].forEach((kw) => {
      const y = pad.top + plotH * (1 - kw / 220);
      this.ctx.beginPath();
      this.ctx.moveTo(pad.left, y);
      this.ctx.lineTo(width - pad.right, y);
      this.ctx.stroke();
      this.ctx.fillText(`${kw}k`, pad.left - 4, y);
    });

    // X axis ticks: 0%, 50%, 100%
    this.ctx.textAlign = 'center';
    this.ctx.textBaseline = 'top';
    [0, 20, 50, 80, 100].forEach((soc) => {
      const x = pad.left + (soc / 100) * plotW;
      this.ctx.fillText(`${soc}%`, x, height - pad.bottom + 6);
    });

    // Draw AC 11 kW Flat Reference Line
    const yAc = pad.top + plotH * (1 - 11 / 220);
    this.ctx.strokeStyle = this.isDark ? 'rgba(255, 255, 255, 0.25)' : 'rgba(0, 0, 0, 0.25)';
    this.ctx.setLineDash([3, 3]);
    this.ctx.beginPath();
    this.ctx.moveTo(pad.left, yAc);
    this.ctx.lineTo(width - pad.right, yAc);
    this.ctx.stroke();
    this.ctx.setLineDash([]);

    // Draw DC 205 kW Fast Charge Power Curve
    this.ctx.beginPath();
    for (let soc = 0; soc <= 100; soc++) {
      const x = pad.left + (soc / 100) * plotW;
      const kw = this.getPowerAtSoc(soc);
      const y = pad.top + plotH * (1 - kw / 220);
      if (soc === 0) this.ctx.moveTo(x, y);
      else this.ctx.lineTo(x, y);
    }
    this.ctx.strokeStyle = this.isDark ? '#d89f5f' : '#955d26';
    this.ctx.lineWidth = 2.2;
    this.ctx.stroke();

    // Area fill under curve
    this.ctx.lineTo(pad.left + plotW, pad.top + plotH);
    this.ctx.lineTo(pad.left, pad.top + plotH);
    this.ctx.closePath();
    const grad = this.ctx.createLinearGradient(0, pad.top, 0, pad.top + plotH);
    grad.addColorStop(0, this.isDark ? 'rgba(216, 159, 95, 0.28)' : 'rgba(216, 159, 95, 0.18)');
    grad.addColorStop(1, 'rgba(216, 159, 95, 0.0)');
    this.ctx.fillStyle = grad;
    this.ctx.fill();

    // Active Target SoC Indicator
    const targetX = pad.left + (this.currentSoc / 100) * plotW;
    const targetKw = this.getPowerAtSoc(this.currentSoc);
    const targetY = pad.top + plotH * (1 - targetKw / 220);

    // Target SoC dotted line
    this.ctx.strokeStyle = this.isDark ? '#d89f5f' : '#955d26';
    this.ctx.lineWidth = 1;
    this.ctx.setLineDash([2, 2]);
    this.ctx.beginPath();
    this.ctx.moveTo(targetX, pad.top);
    this.ctx.lineTo(targetX, pad.top + plotH);
    this.ctx.stroke();
    this.ctx.setLineDash([]);

    // Target dot
    this.ctx.fillStyle = this.isDark ? '#101113' : '#ffffff';
    this.ctx.strokeStyle = this.isDark ? '#d89f5f' : '#955d26';
    this.ctx.lineWidth = 2.5;
    this.ctx.beginPath();
    this.ctx.arc(targetX, targetY, 4, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.stroke();

    // Hover Scrub Indicator
    if (this.isHovered && this.hoverSoc !== this.currentSoc) {
      const hoverX = pad.left + (this.hoverSoc / 100) * plotW;
      const hoverKw = this.getPowerAtSoc(this.hoverSoc);
      const hoverY = pad.top + plotH * (1 - hoverKw / 220);

      this.ctx.strokeStyle = this.isDark ? 'rgba(255, 255, 255, 0.4)' : 'rgba(0, 0, 0, 0.4)';
      this.ctx.lineWidth = 1;
      this.ctx.beginPath();
      this.ctx.moveTo(hoverX, pad.top);
      this.ctx.lineTo(hoverX, pad.top + plotH);
      this.ctx.stroke();

      this.ctx.fillStyle = this.isDark ? '#ffffff' : '#000000';
      this.ctx.beginPath();
      this.ctx.arc(hoverX, hoverY, 3, 0, Math.PI * 2);
      this.ctx.fill();
    }
  }
}
