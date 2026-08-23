/**
 * @file ThreeMetricsField.ts
 * @description Interactive Three.js 3D Telemetry Constellation & Reactive Particle Canvas
 * for the 12-Card Engineering Metrics Grid in Section 07 (#native).
 * Features:
 * - Magnetic 3D particle constellation reacting to cursor physics
 * - Card-specific telemetry pulse modes (Charging 60s, Deep Sleep 15m, ProMotion 120Hz, etc.)
 * - Automatic pause via IntersectionObserver when off-screen
 * - Reduced motion support
 */

import * as THREE from 'three';

interface TelemetryTheme {
  primary: THREE.Color;
  secondary: THREE.Color;
  speed: number;
  waveFreq: number;
  dispersion: number;
}

const THEMES: Record<string, TelemetryTheme> = {
  default: {
    primary: new THREE.Color(0xd4af37), // Swedish Gold
    secondary: new THREE.Color(0x0a84ff), // Swedish Blue
    speed: 0.8,
    waveFreq: 1.2,
    dispersion: 1.0,
  },
  charging: {
    primary: new THREE.Color(0x30d158), // Electric Charging Green
    secondary: new THREE.Color(0x64d2ff),
    speed: 2.2,
    waveFreq: 2.5,
    dispersion: 1.4,
  },
  sleep: {
    primary: new THREE.Color(0x5e5ce6), // Deep Sleep Indigo
    secondary: new THREE.Color(0x0a84ff),
    speed: 0.3,
    waveFreq: 0.6,
    dispersion: 0.8,
  },
  promotion: {
    primary: new THREE.Color(0xff9f0a), // 120Hz ProMotion Amber
    secondary: new THREE.Color(0xffd60a),
    speed: 2.8,
    waveFreq: 3.2,
    dispersion: 1.8,
  },
  privacy: {
    primary: new THREE.Color(0x32d74b), // Secure Green
    secondary: new THREE.Color(0x00e5ff),
    speed: 1.0,
    waveFreq: 1.5,
    dispersion: 1.1,
  },
  fleet: {
    primary: new THREE.Color(0xd4af37),
    secondary: new THREE.Color(0xff375f), // Crimson Fleet Accent
    speed: 1.5,
    waveFreq: 1.8,
    dispersion: 1.3,
  },
};

export class ThreeMetricsField {
  private container: HTMLElement;
  private canvas!: HTMLCanvasElement;
  private renderer!: THREE.WebGLRenderer;
  private scene!: THREE.Scene;
  private camera!: THREE.PerspectiveCamera;
  private clock = new THREE.Clock();
  private animId: number | null = null;
  private isVisible = false;
  private isReducedMotion = false;

  // Particle System
  private particleCount = 140;
  private pointsMesh!: THREE.Points;
  private linesMesh!: THREE.LineSegments;
  private positions!: Float32Array;
  private initialPositions!: Float32Array;
  private colors!: Float32Array;
  private velocities!: Float32Array;

  // Mouse & Interaction
  private mouse = new THREE.Vector2(0, 0);
  private targetMouse = new THREE.Vector2(0, 0);
  private hoveredCard: HTMLElement | null = null;
  private currentTheme: TelemetryTheme = { ...THEMES.default };
  private targetTheme: TelemetryTheme = { ...THEMES.default };

  constructor(containerId: string) {
    const el = document.getElementById(containerId);
    if (!el) throw new Error(`Container #${containerId} not found`);
    this.container = el;

    this.isReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.initScene();
    this.initParticles();
    this.initCardListeners();
    this.initObserver();
    this.onResize();

    window.addEventListener('resize', this.onResize, { passive: true });
    this.container.addEventListener('mousemove', this.onMouseMove, { passive: true });
    this.container.addEventListener('mouseleave', this.onMouseLeave, { passive: true });
  }

  private initScene(): void {
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'metrics-three-canvas';
    this.canvas.setAttribute('aria-hidden', 'true');
    this.container.style.position = 'relative';
    this.container.insertBefore(this.canvas, this.container.firstChild);

    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(50, 1, 0.1, 1000);
    this.camera.position.z = 85;

    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      alpha: true,
      antialias: true,
      powerPreference: 'high-performance',
    });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.setClearColor(0x000000, 0);
  }

  private initParticles(): void {
    this.positions = new Float32Array(this.particleCount * 3);
    this.initialPositions = new Float32Array(this.particleCount * 3);
    this.colors = new Float32Array(this.particleCount * 3);
    this.velocities = new Float32Array(this.particleCount * 3);

    const radius = 65;
    for (let i = 0; i < this.particleCount; i++) {
      const idx = i * 3;
      const u = Math.random();
      const v = Math.random();
      const theta = u * 2.0 * Math.PI;
      const phi = Math.acos(2.0 * v - 1.0);
      const r = Math.cbrt(Math.random()) * radius;

      const x = r * Math.sin(phi) * Math.cos(theta) * 1.5;
      const y = (r * Math.sin(phi) * Math.sin(theta)) * 0.7;
      const z = (r * Math.cos(phi)) * 0.5;

      this.positions[idx] = x;
      this.positions[idx + 1] = y;
      this.positions[idx + 2] = z;

      this.initialPositions[idx] = x;
      this.initialPositions[idx + 1] = y;
      this.initialPositions[idx + 2] = z;

      this.velocities[idx] = (Math.random() - 0.5) * 0.2;
      this.velocities[idx + 1] = (Math.random() - 0.5) * 0.2;
      this.velocities[idx + 2] = (Math.random() - 0.5) * 0.2;

      // Initial Gold / Blue mix
      const isGold = Math.random() > 0.4;
      const col = isGold ? THEMES.default.primary : THEMES.default.secondary;
      this.colors[idx] = col.r;
      this.colors[idx + 1] = col.g;
      this.colors[idx + 2] = col.b;
    }

    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.BufferAttribute(this.positions, 3));
    geometry.setAttribute('color', new THREE.BufferAttribute(this.colors, 3));

    // Particle sprite
    const pCanvas = document.createElement('canvas');
    pCanvas.width = 32;
    pCanvas.height = 32;
    const ctx = pCanvas.getContext('2d');
    if (ctx) {
      const grad = ctx.createRadialGradient(16, 16, 0, 16, 16, 16);
      grad.addColorStop(0, 'rgba(255, 255, 255, 1)');
      grad.addColorStop(0.3, 'rgba(255, 255, 255, 0.8)');
      grad.addColorStop(0.7, 'rgba(255, 255, 255, 0.15)');
      grad.addColorStop(1, 'rgba(255, 255, 255, 0)');
      ctx.fillStyle = grad;
      ctx.fillRect(0, 0, 32, 32);
    }
    const pTexture = new THREE.CanvasTexture(pCanvas);

    const pointsMat = new THREE.PointsMaterial({
      size: 3.2,
      vertexColors: true,
      transparent: true,
      opacity: 0.75,
      map: pTexture,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });

    this.pointsMesh = new THREE.Points(geometry, pointsMat);
    this.scene.add(this.pointsMesh);

    // Line segments connecting nearby nodes
    const maxLineSegments = this.particleCount * 4;
    const linePositions = new Float32Array(maxLineSegments * 6);
    const lineColors = new Float32Array(maxLineSegments * 6);

    const lineGeom = new THREE.BufferGeometry();
    lineGeom.setAttribute('position', new THREE.BufferAttribute(linePositions, 3));
    lineGeom.setAttribute('color', new THREE.BufferAttribute(lineColors, 3));

    const lineMat = new THREE.LineBasicMaterial({
      vertexColors: true,
      transparent: true,
      opacity: 0.22,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });

    this.linesMesh = new THREE.LineSegments(lineGeom, lineMat);
    this.scene.add(this.linesMesh);
  }

  private initCardListeners(): void {
    const cards = this.container.querySelectorAll<HTMLElement>('.metric-card');
    cards.forEach((card) => {
      const label = card.querySelector('.metric-label')?.textContent?.toLowerCase() || '';
      const val = card.querySelector('.metric-value')?.textContent?.toLowerCase() || '';

      let themeKey = 'default';
      if (val.includes('60 s') || label.includes('charging')) themeKey = 'charging';
      else if (val.includes('15 min') || label.includes('sleep')) themeKey = 'sleep';
      else if (val.includes('120 hz') || label.includes('promotion')) themeKey = 'promotion';
      else if (val === '0' || label.includes('trackers') || label.includes('offline')) themeKey = 'privacy';
      else if (val.includes('16+') || val === '4' || label.includes('vehicles') || label.includes('powertrain')) themeKey = 'fleet';

      card.setAttribute('data-telemetry-theme', themeKey);

      card.addEventListener('mouseenter', (e) => {
        this.hoveredCard = card;
        this.targetTheme = THEMES[themeKey] || THEMES.default;
        this.applyCardTilt(card, e);
      });

      card.addEventListener('mousemove', (e) => {
        if (this.hoveredCard === card) {
          this.applyCardTilt(card, e);
        }
      });

      card.addEventListener('mouseleave', () => {
        this.hoveredCard = null;
        this.targetTheme = THEMES.default;
        card.style.transform = '';
      });
    });
  }

  private applyCardTilt(card: HTMLElement, e: MouseEvent): void {
    if (this.isReducedMotion) return;
    const rect = card.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const centerX = rect.width / 2;
    const centerY = rect.height / 2;
    const rotateX = ((y - centerY) / centerY) * -6; // max 6deg
    const rotateY = ((x - centerX) / centerX) * 6;

    card.style.transform = `perspective(800px) rotateX(${rotateX.toFixed(2)}deg) rotateY(${rotateY.toFixed(2)}deg) translateY(-4px)`;
  }

  private onMouseMove = (e: MouseEvent): void => {
    const rect = this.container.getBoundingClientRect();
    const x = ((e.clientX - rect.left) / rect.width) * 2 - 1;
    const y = -(((e.clientY - rect.top) / rect.height) * 2 - 1);
    this.targetMouse.set(x * 25, y * 20);
  };

  private onMouseLeave = (): void => {
    this.targetMouse.set(0, 0);
    this.targetTheme = THEMES.default;
  };

  private initObserver(): void {
    const observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        this.isVisible = entry.isIntersecting;
        if (this.isVisible && !this.animId) {
          this.clock.start();
          this.animate();
        } else if (!this.isVisible && this.animId) {
          cancelAnimationFrame(this.animId);
          this.animId = null;
        }
      },
      { threshold: 0.05 }
    );
    observer.observe(this.container);
  }

  private onResize = (): void => {
    const rect = this.container.getBoundingClientRect();
    const width = rect.width;
    const height = Math.max(rect.height, 400);

    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();

    this.renderer.setSize(width, height);
  };

  private animate = (): void => {
    this.animId = requestAnimationFrame(this.animate);
    const delta = Math.min(this.clock.getDelta(), 0.1);
    const elapsedTime = this.clock.getElapsedTime();

    // Smooth Mouse Interpolation
    this.mouse.lerp(this.targetMouse, delta * 4);

    // Smooth Theme Interpolation
    this.currentTheme.primary.lerp(this.targetTheme.primary, delta * 3);
    this.currentTheme.secondary.lerp(this.targetTheme.secondary, delta * 3);
    this.currentTheme.speed += (this.targetTheme.speed - this.currentTheme.speed) * delta * 3;
    this.currentTheme.waveFreq += (this.targetTheme.waveFreq - this.currentTheme.waveFreq) * delta * 3;

    // Update Particles
    const posAttr = this.pointsMesh.geometry.getAttribute('position') as THREE.BufferAttribute;
    const colAttr = this.pointsMesh.geometry.getAttribute('color') as THREE.BufferAttribute;
    const posArray = posAttr.array as Float32Array;
    const colArray = colAttr.array as Float32Array;

    const linePosAttr = this.linesMesh.geometry.getAttribute('position') as THREE.BufferAttribute;
    const lineColAttr = this.linesMesh.geometry.getAttribute('color') as THREE.BufferAttribute;
    const linePosArray = linePosAttr.array as Float32Array;
    const lineColArray = lineColAttr.array as Float32Array;

    let lineIndex = 0;
    const connectionDist = 18.0;

    for (let i = 0; i < this.particleCount; i++) {
      const idx = i * 3;
      const initX = this.initialPositions[idx];
      const initY = this.initialPositions[idx + 1];
      const initZ = this.initialPositions[idx + 2];

      // Wave motion with time & theme speed
      const wave = Math.sin(elapsedTime * this.currentTheme.speed + initX * 0.05 + initY * 0.05) * 3.5;
      const waveCos = Math.cos(elapsedTime * this.currentTheme.speed * 0.8 + initZ * 0.05) * 2.5;

      // Magnetic mouse attraction / ripple
      const dx = this.mouse.x - posArray[idx];
      const dy = this.mouse.y - posArray[idx + 1];
      const dist = Math.sqrt(dx * dx + dy * dy);
      const influence = Math.max(0, 1.0 - dist / 35.0) * 8.0;

      posArray[idx] = initX + (dx / (dist + 0.001)) * influence + waveCos;
      posArray[idx + 1] = initY + (dy / (dist + 0.001)) * influence + wave;
      posArray[idx + 2] = initZ + Math.sin(elapsedTime + i) * 1.5;

      // Color Lerp based on spatial position & theme
      const mixRatio = (Math.sin(elapsedTime + i * 0.2) + 1) * 0.5;
      const r = THREE.MathUtils.lerp(this.currentTheme.primary.r, this.currentTheme.secondary.r, mixRatio);
      const g = THREE.MathUtils.lerp(this.currentTheme.primary.g, this.currentTheme.secondary.g, mixRatio);
      const b = THREE.MathUtils.lerp(this.currentTheme.primary.b, this.currentTheme.secondary.b, mixRatio);

      colArray[idx] = r;
      colArray[idx + 1] = g;
      colArray[idx + 2] = b;

      // Connect lines
      for (let j = i + 1; j < this.particleCount; j++) {
        if (lineIndex >= linePosArray.length - 6) break;
        const jdx = j * 3;
        const lx = posArray[idx] - posArray[jdx];
        const ly = posArray[idx + 1] - posArray[jdx + 1];
        const lz = posArray[idx + 2] - posArray[jdx + 2];
        const lDist = Math.sqrt(lx * lx + ly * ly + lz * lz);

        if (lDist < connectionDist) {
          const alpha = 1.0 - lDist / connectionDist;

          linePosArray[lineIndex] = posArray[idx];
          linePosArray[lineIndex + 1] = posArray[idx + 1];
          linePosArray[lineIndex + 2] = posArray[idx + 2];

          linePosArray[lineIndex + 3] = posArray[jdx];
          linePosArray[lineIndex + 4] = posArray[jdx + 1];
          linePosArray[lineIndex + 5] = posArray[jdx + 2];

          lineColArray[lineIndex] = r * alpha;
          lineColArray[lineIndex + 1] = g * alpha;
          lineColArray[lineIndex + 2] = b * alpha;

          lineColArray[lineIndex + 3] = r * alpha;
          lineColArray[lineIndex + 4] = g * alpha;
          lineColArray[lineIndex + 5] = b * alpha;

          lineIndex += 6;
        }
      }
    }

    // Zero out unused line segments
    for (let k = lineIndex; k < linePosArray.length; k++) {
      linePosArray[k] = 0;
      lineColArray[k] = 0;
    }

    posAttr.needsUpdate = true;
    colAttr.needsUpdate = true;
    linePosAttr.needsUpdate = true;
    lineColAttr.needsUpdate = true;

    // Gentle camera parallax
    this.camera.position.x += (this.mouse.x * 0.15 - this.camera.position.x) * delta * 2;
    this.camera.position.y += (this.mouse.y * 0.15 - this.camera.position.y) * delta * 2;
    this.camera.lookAt(0, 0, 0);

    this.renderer.render(this.scene, this.camera);
  };

  public setTheme(isDark: boolean): void {
    if (this.pointsMesh && this.pointsMesh.material) {
      (this.pointsMesh.material as THREE.PointsMaterial).opacity = isDark ? 0.85 : 0.65;
    }
    if (this.linesMesh && this.linesMesh.material) {
      (this.linesMesh.material as THREE.LineBasicMaterial).opacity = isDark ? 0.28 : 0.18;
    }
  }

  public destroy(): void {
    if (this.animId) cancelAnimationFrame(this.animId);
    window.removeEventListener('resize', this.onResize);
    this.renderer.dispose();
    this.canvas.remove();
  }
}
