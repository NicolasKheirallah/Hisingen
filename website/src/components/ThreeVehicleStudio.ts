/**
 * ThreeVehicleStudio — photographic turntable with shader crossfade,
 * render-on-demand scheduling, palette-correct wind tunnel, projected
 * engineering callouts, scroll-linked camera dolly and night-mode lighting.
 */

import * as THREE from 'three';

const baseUrl = (import.meta.env?.BASE_URL || '/').replace(/\/$/, '') + '/';

export type StudioMode = 'orbit' | 'parallax' | 'windtunnel';

interface TurntableFrame {
  id: string;
  url: string;
  angle: number;
  texture?: THREE.Texture;
}

interface SpecialView {
  index: number;
  url: string;
  texture?: THREE.Texture;
}

interface CalloutDef {
  frameId: string;
  u: number;
  v: number;
  label: string;
  sub: string;
  dx: number;
  dy: number;
}

const PLANE_W = 3.6;
const PLANE_H = 2.025;
const TWO_PI = Math.PI * 2;
const BASE_FRUSTUM = 2.15;
const WIDE_FRUSTUM = 2.65;

export class ThreeVehicleStudio {
  private container: HTMLElement;
  private canvas: HTMLCanvasElement;
  private renderer!: THREE.WebGLRenderer;
  private scene!: THREE.Scene;
  private camera!: THREE.OrthographicCamera;
  private isVisible = false;
  private contextLost = false;

  // Render-on-demand scheduling
  private rafId: number | null = null;
  private dirty = true;
  private lastTick = 0;

  // Mode state
  private currentMode: StudioMode = 'orbit';
  private isDark = false;
  private isReducedMotion = false;
  private ready = false;

  // Turntable — one shared texture per unique asset
  private frames: TurntableFrame[] = [
    { id: 'front34', url: `${baseUrl}assets/vehicle/polestar2-front-threequarter.webp`, angle: 0.0 },
    { id: 'front', url: `${baseUrl}assets/vehicle/polestar2-front.webp`, angle: Math.PI * 0.25 },
    { id: 'side', url: `${baseUrl}assets/vehicle/polestar2-side-profile.webp`, angle: Math.PI * 0.5 },
    { id: 'rear34', url: `${baseUrl}assets/vehicle/polestar2-rear-threequarter.webp`, angle: Math.PI * 0.75 },
    { id: 'rear', url: `${baseUrl}assets/vehicle/polestar2-rear.webp`, angle: Math.PI },
    { id: 'side2', url: `${baseUrl}assets/vehicle/polestar2-side-profile.webp`, angle: Math.PI * 1.5 },
    { id: 'front34r', url: `${baseUrl}assets/vehicle/polestar2-front-threequarter.webp`, angle: Math.PI * 1.75 },
  ];
  private specialViews: SpecialView[] = [
    { index: 5, url: `${baseUrl}assets/vehicle/polestar2-overhead.webp` },
    { index: 6, url: `${baseUrl}assets/vehicle/polestar2-interior.webp` },
    { index: 7, url: `${baseUrl}assets/vehicle/polestar_outline.svg` },
  ];

  private currentAngle = 0;
  private targetAngle = 0;
  private angularVelocity = 0;
  private isDragging = false;
  private lastPointerX = 0;
  private specialIndex = -1;
  private showingSpecial = false;

  // Generic texture crossfade (enter/leave special views)
  private fadeActive = false;
  private fadeWeight = 0;
  private fadeFrom: THREE.Texture | null = null;
  private fadeTo: THREE.Texture | null = null;

  // 2.5D parallax + crossfade material
  private carPlaneMesh!: THREE.Mesh;
  private parallaxMaterial!: THREE.ShaderMaterial;
  private mouseNorm = new THREE.Vector2(0, 0);
  private targetMouseNorm = new THREE.Vector2(0, 0);
  private activePair = '';

  // Wind tunnel
  private particleCount = 1600;
  private particleSystem!: THREE.Points;
  private particleMaterial!: THREE.ShaderMaterial;
  private windSpeed = 1.0;
  private targetWindSpeed = 1.0;
  private windActive = 0;
  private windActiveTarget = 0;

  // Ground shadow + night lighting
  private shadowPlane!: THREE.Mesh;
  private noseGlow!: THREE.Mesh;
  private lightPool!: THREE.Mesh;
  private glowIntensity = 0;
  private glowTarget = 0;

  // Scroll-linked camera
  private currentFrustum = WIDE_FRUSTUM;
  private targetFrustum = WIDE_FRUSTUM;

  // Projected annotations
  private callouts: Array<{ def: CalloutDef; el: HTMLElement; anchor: TurntableFrame | undefined }> = [];
  private projected = new THREE.Vector3();

  // Nose anchor per frame for the headlight glow (UV space of that frame)
  private noseAnchors: Record<string, { u: number; v: number }> = {
    front34: { u: 0.24, v: 0.56 },
    front: { u: 0.5, v: 0.66 },
    side: { u: 0.86, v: 0.52 },
    side2: { u: 0.14, v: 0.52 },
  };

  private resizeObserver: ResizeObserver | null = null;
  private themeObserver: MutationObserver | null = null;
  private mediaQuery: MediaQueryList | null = null;
  private onThemeMedia: (() => void) | null = null;
  private onScroll: (() => void) | null = null;
  private onVisChange: (() => void) | null = null;
  private disposed = false;

  constructor(containerId: string) {
    const el = document.getElementById(containerId);
    if (!el) throw new Error(`Container #${containerId} not found`);
    this.container = el;

    this.isReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.refreshDark();

    this.canvas = document.createElement('canvas');
    this.canvas.className = 'three-studio-canvas';
    this.canvas.setAttribute('aria-hidden', 'true');
    this.container.appendChild(this.canvas);

    this.initScene();
    this.createCarMesh();
    this.createGroundShadow();
    this.createNightLighting();
    this.createWindTunnelParticles();
    this.loadTextures();
    this.createCallouts();
    this.setupEvents();
    this.setupObserver();
    this.onResize();

    this.container.classList.add('is-loading');
  }

  /* ---------- scene ---------- */

  private initScene(): void {
    this.scene = new THREE.Scene();
    this.camera = new THREE.OrthographicCamera(-2, 2, 1.125, -1.125, 0.1, 100);
    this.camera.position.set(0, 0, 10);
    this.camera.lookAt(0, 0, 0);
    this.applyFrustum(this.currentFrustum);

    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      alpha: true,
      antialias: true,
      powerPreference: 'high-performance',
    });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));

    this.canvas.addEventListener('webglcontextlost', (e) => {
      e.preventDefault();
      this.contextLost = true;
      this.stopLoop();
      this.container.classList.add('is-fallback');
    });
    this.canvas.addEventListener('webglcontextrestored', () => {
      this.contextLost = false;
      this.container.classList.remove('is-fallback');
      this.dirty = true;
      this.requestRender();
    });
  }

  private applyFrustum(height: number): void {
    const aspect = Math.max(0.1, this.container.clientWidth / Math.max(1, this.container.clientHeight));
    const frustumHeight = height;
    const frustumWidth = frustumHeight * aspect;
    this.camera.left = -frustumWidth / 2;
    this.camera.right = frustumWidth / 2;
    this.camera.top = frustumHeight / 2;
    this.camera.bottom = -frustumHeight / 2;
    this.camera.updateProjectionMatrix();
  }

  /* ---------- textures (single shared load pass) ---------- */

  private loadTextures(): void {
    const loader = new THREE.TextureLoader();
    const byUrl = new Map<string, THREE.Texture>();
    let pending = 0;
    let primaryDone = false;

    const queue = (url: string, onDone: (tex: THREE.Texture) => void): void => {
      const existing = byUrl.get(url);
      if (existing) {
        onDone(existing);
        return;
      }
      pending++;
      loader.load(
        url,
        (tex) => {
          tex.minFilter = THREE.LinearFilter;
          tex.magFilter = THREE.LinearFilter;
          tex.colorSpace = THREE.SRGBColorSpace;
          byUrl.set(url, tex);
          pending--;
          onDone(tex);
          if (pending === 0) this.container.classList.add('is-settled');
        },
        undefined,
        () => {
          pending--;
          if (pending === 0) this.container.classList.add('is-settled');
        },
      );
    };

    for (const frame of this.frames) {
      queue(frame.url, (tex) => {
        frame.texture = tex;
        if (frame.id === 'front34' && !primaryDone) {
          primaryDone = true;
          this.markReady(tex);
        }
      });
    }
    for (const view of this.specialViews) {
      queue(view.url, (tex) => {
        view.texture = tex;
      });
    }
  }

  private markReady(tex: THREE.Texture): void {
    this.ready = true;
    this.parallaxMaterial.uniforms.uTexA.value = tex;
    this.parallaxMaterial.uniforms.uTexB.value = tex;
    this.parallaxMaterial.uniforms.uBlend.value = 0;
    this.container.classList.remove('is-loading');
    this.container.classList.add('is-ready');
    this.requestRender();
  }

  /* ---------- car plane with crossfade + clearcoat ---------- */

  private createCarMesh(): void {
    const geom = new THREE.PlaneGeometry(PLANE_W, PLANE_H, 32, 32);

    const vertexShader = `
      uniform vec2 uMouse;
      uniform float uParallaxStrength;
      varying vec2 vUv;

      void main() {
        vUv = uv;
        vec3 pos = position;
        float depthMask = sin(uv.x * 3.14159) * 0.25;
        pos.z += depthMask * 0.3;
        pos.x += uMouse.x * depthMask * uParallaxStrength * 0.15;
        pos.y += uMouse.y * depthMask * uParallaxStrength * 0.08;
        gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
      }
    `;

    const fragmentShader = `
      uniform sampler2D uTexA;
      uniform sampler2D uTexB;
      uniform float uBlend;
      uniform vec2 uMouse;
      uniform float uLightSweep;
      uniform float uIsDark;
      uniform float uSpecularIntensity;
      varying vec2 vUv;

      void main() {
        vec4 ca = texture2D(uTexA, vUv);
        vec4 cb = texture2D(uTexB, vUv);
        vec4 baseColor = mix(ca, cb, clamp(uBlend, 0.0, 1.0));
        if (baseColor.a < 0.02) discard;

        // Studio light bar follows the pointer
        float lightX = uLightSweep * 1.4 - 0.2;
        float distToLight = abs(vUv.x - lightX);
        float specularBar = smoothstep(0.35, 0.0, distToLight) * 0.30;

        vec2 lightOffset = vUv - (uMouse * 0.3 + 0.5);
        float mouseSpec = smoothstep(0.4, 0.0, length(lightOffset)) * 0.16;

        float dim = mix(1.0, 0.82, uIsDark);
        float totalSheen = (specularBar + mouseSpec) * uSpecularIntensity * mix(0.9, 1.15, uIsDark);

        vec3 highlightColor = mix(vec3(1.0, 1.0, 1.0), vec3(0.95, 0.82, 0.65), 0.35);
        vec3 body = baseColor.rgb * dim;
        vec3 finalRgb = body + highlightColor * totalSheen * baseColor.a;

        gl_FragColor = vec4(finalRgb, baseColor.a);
      }
    `;

    this.parallaxMaterial = new THREE.ShaderMaterial({
      vertexShader,
      fragmentShader,
      uniforms: {
        uTexA: { value: null },
        uTexB: { value: null },
        uBlend: { value: 1 },
        uMouse: { value: new THREE.Vector2(0, 0) },
        uParallaxStrength: { value: 1.0 },
        uLightSweep: { value: this.isReducedMotion ? 0.42 : 0.5 },
        uIsDark: { value: this.isDark ? 1.0 : 0.0 },
        uSpecularIntensity: { value: 0.8 },
      },
      transparent: true,
      depthWrite: false,
    });

    this.carPlaneMesh = new THREE.Mesh(geom, this.parallaxMaterial);
    this.carPlaneMesh.position.set(0, 0.05, 0);
    this.scene.add(this.carPlaneMesh);
  }

  /* ---------- ground shadow + night lighting ---------- */

  private createGroundShadow(): void {
    const geom = new THREE.PlaneGeometry(3.4, 0.65);
    const cv = document.createElement('canvas');
    cv.width = 256;
    cv.height = 64;
    const ctx = cv.getContext('2d')!;
    const grad = ctx.createRadialGradient(128, 32, 10, 128, 32, 120);
    grad.addColorStop(0, 'rgba(0, 0, 0, 0.45)');
    grad.addColorStop(0.5, 'rgba(0, 0, 0, 0.18)');
    grad.addColorStop(1, 'rgba(0, 0, 0, 0)');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, 256, 64);

    const mat = new THREE.MeshBasicMaterial({
      map: new THREE.CanvasTexture(cv),
      transparent: true,
      opacity: this.isDark ? 0.75 : 0.4,
      depthWrite: false,
    });
    this.shadowPlane = new THREE.Mesh(geom, mat);
    this.shadowPlane.position.set(0, -0.68, -0.1);
    this.scene.add(this.shadowPlane);
  }

  private makeGlowTexture(inner: string, outer: string): THREE.CanvasTexture {
    const cv = document.createElement('canvas');
    cv.width = 128;
    cv.height = 128;
    const ctx = cv.getContext('2d')!;
    const grad = ctx.createRadialGradient(64, 64, 2, 64, 64, 62);
    grad.addColorStop(0, inner);
    grad.addColorStop(0.4, outer);
    grad.addColorStop(1, 'rgba(255, 240, 210, 0)');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, 128, 128);
    return new THREE.CanvasTexture(cv);
  }

  private createNightLighting(): void {
    const glowMat = new THREE.MeshBasicMaterial({
      map: this.makeGlowTexture('rgba(255, 244, 220, 0.9)', 'rgba(255, 230, 180, 0.35)'),
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.noseGlow = new THREE.Mesh(new THREE.PlaneGeometry(1.15, 1.15), glowMat);
    this.noseGlow.position.set(0, 0.05, 0.4);
    this.scene.add(this.noseGlow);

    const poolCv = document.createElement('canvas');
    poolCv.width = 256;
    poolCv.height = 96;
    const pctx = poolCv.getContext('2d')!;
    const poolGrad = pctx.createRadialGradient(128, 48, 4, 128, 48, 120);
    poolGrad.addColorStop(0, 'rgba(255, 236, 196, 0.55)');
    poolGrad.addColorStop(1, 'rgba(255, 236, 196, 0)');
    pctx.fillStyle = poolGrad;
    pctx.save();
    pctx.translate(128, 48);
    pctx.scale(1, 0.375);
    pctx.translate(-128, -48);
    pctx.fillRect(0, 0, 256, 96);
    pctx.restore();
    const poolMat = new THREE.MeshBasicMaterial({
      map: new THREE.CanvasTexture(poolCv),
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.lightPool = new THREE.Mesh(new THREE.PlaneGeometry(2.2, 2.2), poolMat);
    this.lightPool.position.set(0, -0.62, -0.05);
    this.scene.add(this.lightPool);
  }

  /* ---------- wind tunnel (palette: graphite white → amber) ---------- */

  private createWindTunnelParticles(): void {
    const geometry = new THREE.BufferGeometry();
    const positions = new Float32Array(this.particleCount * 3);
    const speeds = new Float32Array(this.particleCount);
    const offsets = new Float32Array(this.particleCount);
    const layers = new Float32Array(this.particleCount);

    for (let i = 0; i < this.particleCount; i++) {
      const band = Math.floor(Math.random() * 14);
      const baseY = -0.58 + band * 0.11;
      positions[i * 3 + 0] = -2.2 + Math.random() * 4.4;
      positions[i * 3 + 1] = baseY + (Math.random() - 0.5) * 0.03;
      positions[i * 3 + 2] = (Math.random() - 0.5) * 0.3;
      speeds[i] = 0.95 + Math.random() * 0.35;
      offsets[i] = Math.random() * 100;
      layers[i] = band / 13.0;
    }

    geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geometry.setAttribute('aSpeed', new THREE.BufferAttribute(speeds, 1));
    geometry.setAttribute('aOffset', new THREE.BufferAttribute(offsets, 1));
    geometry.setAttribute('aLayer', new THREE.BufferAttribute(layers, 1));

    const vertexShader = `
      uniform float uTime;
      uniform float uWindSpeed;
      uniform float uActive;
      uniform float uPixelRatio;
      attribute float aSpeed;
      attribute float aOffset;
      attribute float aLayer;
      varying float vAlpha;
      varying vec3 vColor;

      void main() {
        vec3 pos = position;
        float flowX = 2.2 - mod((uTime * aSpeed * uWindSpeed * 1.55) + aOffset, 4.4);
        pos.x = flowX;

        float u = (1.38 - pos.x) / 2.73;

        if (pos.y > -0.38) {
          if (u >= 0.0 && u <= 1.0) {
            float hoodRamp = smoothstep(0.0, 0.30, u) * 0.20;
            float roofPeak = sin(smoothstep(0.20, 0.80, u) * 3.14159) * 0.36;
            float fastbackTaper = smoothstep(0.70, 1.0, u) * -0.14;
            float upperFlow = hoodRamp + roofPeak + fastbackTaper;
            float heightWeight = smoothstep(-0.35, 0.8, pos.y);
            pos.y += upperFlow * (0.35 + aLayer * 0.65) * heightWeight;
          } else if (u > 1.0) {
            float wakeDecay = exp(-(u - 1.0) * 1.6) * 0.12;
            float turbulence = sin(uTime * 6.0 + aOffset) * 0.015 * smoothstep(1.0, 1.8, u);
            pos.y += (wakeDecay + turbulence) * smoothstep(-0.35, 0.6, pos.y);
          }
        } else if (u >= 0.70 && u <= 1.1) {
          pos.y += smoothstep(0.70, 1.0, u) * 0.06;
        }

        float edgeFade = smoothstep(2.2, 1.8, pos.x) * smoothstep(-2.2, -1.8, pos.x);
        vAlpha = edgeFade * (0.35 + aLayer * 0.4) * uActive;

        // Graphite white free-stream → amber boundary layer
        vec3 paper = uIsDark > 0.5 ? vec3(0.92, 0.91, 0.88) : vec3(0.72, 0.71, 0.68);
        vec3 graphite = uIsDark > 0.5 ? vec3(0.66, 0.65, 0.62) : vec3(0.45, 0.44, 0.42);
        vec3 amber = vec3(0.85, 0.60, 0.32);

        if (aLayer < 0.35) {
          vColor = mix(paper, graphite, aLayer / 0.35);
        } else {
          vColor = mix(graphite, amber, (aLayer - 0.35) / 0.65);
        }

        vec4 mvPosition = modelViewMatrix * vec4(pos, 1.0);
        gl_PointSize = (1.25 + aLayer * 1.05) * uPixelRatio * uActive;
        gl_Position = projectionMatrix * mvPosition;
      }
    `;

    const fragmentShader = `
      uniform float uIsDark;
      varying float vAlpha;
      varying vec3 vColor;

      void main() {
        if (vAlpha < 0.02) discard;
        vec2 coord = gl_PointCoord - vec2(0.5);
        float dist = length(coord);
        if (dist > 0.5) discard;
        float soft = smoothstep(0.5, 0.05, dist);
        float peak = uIsDark > 0.5 ? 0.7 : 0.55;
        gl_FragColor = vec4(vColor, vAlpha * soft * peak);
      }
    `;

    this.particleMaterial = new THREE.ShaderMaterial({
      vertexShader,
      fragmentShader,
      uniforms: {
        uTime: { value: 0 },
        uWindSpeed: { value: 1.0 },
        uActive: { value: 0.0 },
        uPixelRatio: { value: Math.min(window.devicePixelRatio || 1, 2) },
        uIsDark: { value: this.isDark ? 1.0 : 0.0 },
      },
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });

    this.particleSystem = new THREE.Points(geometry, this.particleMaterial);
    this.particleSystem.position.set(0, 0, 0.2);
    this.scene.add(this.particleSystem);
  }

  /* ---------- projected engineering annotations ---------- */

  private createCallouts(): void {
    const defs: CalloutDef[] = [
      { frameId: 'side', u: 0.5, v: 0.8, label: 'Battery', sub: '78 kWh · floor-mounted', dx: -10, dy: 56 },
      { frameId: 'side', u: 0.22, v: 0.62, label: 'Rear motor', sub: '150 kW · direct drive', dx: -64, dy: -44 },
      { frameId: 'side', u: 0.56, v: 0.26, label: 'Drag', sub: '0.278 Cd fastback', dx: 26, dy: -52 },
      { frameId: 'front34', u: 0.3, v: 0.52, label: 'Pixel LED', sub: 'adaptive headlamps', dx: 30, dy: -40 },
      { frameId: 'front', u: 0.5, v: 0.42, label: 'Pixel LED', sub: 'adaptive headlamps', dx: 40, dy: -30 },
    ];

    for (const def of defs) {
      const el = document.createElement('div');
      el.className = 'studio-callout';
      el.setAttribute('aria-hidden', 'true');
      const anchor = this.frames.find((f) => f.id === def.frameId);
      if (!anchor) continue;
      el.innerHTML = `<span class="callout-dot"></span><span class="callout-text"><strong>${def.label}</strong><em>${def.sub}</em></span>`;
      el.style.setProperty('--callout-dx', `${def.dx}px`);
      el.style.setProperty('--callout-dy', `${def.dy}px`);
      this.container.appendChild(el);
      this.callouts.push({ def, el, anchor });
    }
  }

  private updateCallouts(): void {
    const rect = this.container.getBoundingClientRect();
    const w = rect.width;
    const h = rect.height;
    if (w === 0 || h === 0) return;

    for (const callout of this.callouts) {
      const { def, el, anchor } = callout;
      if (!anchor?.texture || !this.ready || this.specialIndex !== -1 || this.fadeActive || this.container.classList.contains('is-fallback')) {
        el.style.opacity = '0';
        continue;
      }

      // Fade with angular distance to the anchored frame
      let diff = Math.abs(this.currentAngle - anchor.angle) % TWO_PI;
      if (diff > Math.PI) diff = TWO_PI - diff;
      const angleFade = Math.max(0, 1 - diff / 0.42);
      if (angleFade <= 0.01) {
        el.style.opacity = '0';
        continue;
      }

      this.projected.set(
        (def.u - 0.5) * PLANE_W + this.carPlaneMesh.position.x,
        (def.v - 0.5) * PLANE_H + this.carPlaneMesh.position.y,
        0.3,
      );
      this.projected.project(this.camera);

      const px = (this.projected.x * 0.5 + 0.5) * w;
      const py = (-this.projected.y * 0.5 + 0.5) * h;
      el.style.transform = `translate3d(${px.toFixed(1)}px, ${py.toFixed(1)}px, 0)`;
      el.style.opacity = (angleFade * 0.96).toFixed(2);
    }
  }

  /* ---------- events ---------- */

  private setupEvents(): void {
    const onPointerDown = (e: PointerEvent): void => {
      if (this.contextLost) return;
      this.isDragging = true;
      this.lastPointerX = e.clientX;
      this.angularVelocity = 0;
      this.canvas.setPointerCapture(e.pointerId);
      this.requestRender();
    };

    const onPointerMove = (e: PointerEvent): void => {
      const rect = this.canvas.getBoundingClientRect();
      const nx = ((e.clientX - rect.left) / rect.width) * 2 - 1;
      const ny = -(((e.clientY - rect.top) / rect.height) * 2 - 1);
      this.targetMouseNorm.set(nx, ny);

      if (this.isDragging) {
        const deltaX = e.clientX - this.lastPointerX;
        this.angularVelocity = deltaX * 0.008;
        this.targetAngle += this.angularVelocity;
        this.lastPointerX = e.clientX;
      }
      this.requestRender();
    };

    const onPointerUp = (e: PointerEvent): void => {
      this.isDragging = false;
      try {
        this.canvas.releasePointerCapture(e.pointerId);
      } catch {
        /* pointer already released */
      }
      this.requestRender();
    };

    this.canvas.addEventListener('pointerdown', onPointerDown);
    this.canvas.addEventListener('pointermove', onPointerMove, { passive: true });
    this.canvas.addEventListener('pointerup', onPointerUp);
    this.canvas.addEventListener('pointercancel', onPointerUp);

    this.resizeObserver = new ResizeObserver(() => {
      this.onResize();
      this.requestRender();
    });
    this.resizeObserver.observe(this.container);

    // Scroll-linked camera dolly
    this.onScroll = () => {
      if (this.isReducedMotion || !this.isVisible) return;
      const rect = this.container.getBoundingClientRect();
      const vh = window.innerHeight || 1;
      const raw = 1 - (rect.top - vh * 0.22) / (vh * 0.55);
      const p = Math.min(1, Math.max(0, raw));
      const eased = 1 - Math.pow(1 - p, 3);
      this.targetFrustum = WIDE_FRUSTUM + (BASE_FRUSTUM - WIDE_FRUSTUM) * eased;
      this.requestRender();
    };
    window.addEventListener('scroll', this.onScroll, { passive: true });

    // Pause everything when the tab is hidden
    this.onVisChange = () => {
      if (document.hidden) {
        this.stopLoop();
      } else {
        this.requestRender();
      }
    };
    document.addEventListener('visibilitychange', this.onVisChange);

    // Theme changes (toggle + system)
    this.themeObserver = new MutationObserver(() => {
      this.refreshDark();
      this.applyTheme();
    });
    this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    this.mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
    this.onThemeMedia = () => {
      this.refreshDark();
      this.applyTheme();
    };
    this.mediaQuery.addEventListener?.('change', this.onThemeMedia);
  }

  private refreshDark(): void {
    this.isDark =
      document.documentElement.dataset.theme === 'dark' ||
      (!document.documentElement.dataset.theme && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }

  private applyTheme(): void {
    this.parallaxMaterial.uniforms.uIsDark.value = this.isDark ? 1.0 : 0.0;
    this.particleMaterial.uniforms.uIsDark.value = this.isDark ? 1.0 : 0.0;
    (this.shadowPlane.material as THREE.MeshBasicMaterial).opacity = this.isDark ? 0.75 : 0.4;
    this.glowTarget = this.isDark ? 1 : 0;
    this.requestRender();
  }

  /* ---------- public API ---------- */

  public setMode(mode: StudioMode): void {
    this.currentMode = mode;
    if (mode === 'windtunnel') {
      this.windActiveTarget = 1;
      this.targetWindSpeed = Math.max(0.4, this.targetWindSpeed);
      this.targetAngle = Math.PI * 0.5;
      this.currentAngle = Math.PI * 0.5;
      this.leaveSpecial();
    } else {
      this.windActiveTarget = 0;
      if (mode === 'parallax') {
        this.targetAngle = 0;
        this.currentAngle = 0;
        this.leaveSpecial();
      }
    }
    this.requestRender();
  }

  public setWindSpeed(speed: number): void {
    this.targetWindSpeed = Math.max(0, Math.min(2.5, speed));
    this.requestRender();
  }

  public setAngleIndex(index: number): void {
    if (index >= 0 && index < 5) {
      const angleMap = [0, Math.PI * 0.25, Math.PI * 0.5, Math.PI * 0.75, Math.PI];
      this.targetAngle = angleMap[index]!;
      this.currentAngle = this.targetAngle;
      this.angularVelocity = 0;
      this.leaveSpecial();
      this.requestRender();
      return;
    }

    const view = this.specialViews.find((v) => v.index === index);
    if (!view?.texture) return;
    this.specialIndex = index;
    this.startFade(this.parallaxMaterial.uniforms.uTexA.value as THREE.Texture, view.texture);
    this.shadowPlane.visible = index === 5;
    this.requestRender();
  }

  /** Crossfade back from a special view to the photographic turntable. */
  private leaveSpecial(): void {
    this.shadowPlane.visible = true;
    if (this.specialIndex === -1 && !this.fadeActive) return;
    const wasSpecial = this.specialIndex !== -1;
    const specialTex = wasSpecial
      ? ((this.parallaxMaterial.uniforms.uTexB.value as THREE.Texture) ?? this.fadeTo)
      : this.fadeTo;
    this.specialIndex = -1;
    const nearest = this.nearestFrame(this.currentAngle);
    if (this.showingSpecial || this.fadeActive) {
      this.startFade(specialTex ?? nearest?.texture ?? null, nearest?.texture ?? null);
    }
  }

  private startFade(from: THREE.Texture | null, to: THREE.Texture | null): void {
    if (!from || !to) {
      // No source texture — snap instead of fading
      this.fadeActive = false;
      if (to) {
        this.parallaxMaterial.uniforms.uTexA.value = to;
        this.parallaxMaterial.uniforms.uTexB.value = to;
        this.parallaxMaterial.uniforms.uBlend.value = 0;
      }
      this.showingSpecial = this.specialIndex !== -1;
      this.dirty = true;
      return;
    }
    this.fadeFrom = from;
    this.fadeTo = to;
    this.fadeWeight = 0;
    this.fadeActive = true;
    this.dirty = true;
  }

  private nearestFrame(angle: number): TurntableFrame | undefined {
    let best: TurntableFrame | undefined;
    let bestDiff = Infinity;
    for (const frame of this.frames) {
      let diff = Math.abs(angle - frame.angle) % TWO_PI;
      if (diff > Math.PI) diff = TWO_PI - diff;
      if (diff < bestDiff) {
        bestDiff = diff;
        best = frame;
      }
    }
    return best;
  }

  public getMode(): StudioMode {
    return this.currentMode;
  }

  /* ---------- turntable crossfade ---------- */

  private updateTurntable(): void {
    let norm = ((this.currentAngle % TWO_PI) + TWO_PI) % TWO_PI;
    const first = this.frames[0]!;
    const base = first.angle;
    norm = (norm + base) % TWO_PI;

    let prev = this.frames[this.frames.length - 1]!;
    let next = this.frames[0]!;
    let blend = 0;

    for (let i = 0; i < this.frames.length; i++) {
      const a = this.frames[i]!;
      const b = this.frames[(i + 1) % this.frames.length]!;
      const aRel = (a.angle - base + TWO_PI) % TWO_PI;
      let bRel = (b.angle - base + TWO_PI) % TWO_PI;
      if (bRel === 0) bRel = TWO_PI;
      if (norm >= aRel && norm < bRel) {
        prev = a;
        next = b;
        blend = (norm - aRel) / (bRel - aRel);
        break;
      }
    }

    if (!prev.texture || !next.texture) return;

    // Smoothstep the blend so anchor frames carry visual weight
    const eased = blend * blend * (3 - 2 * blend);
    const pair = `${prev.id}>${next.id}`;

    if (this.fadeActive) {
      return;
    }

    if (pair !== this.activePair) {
      this.activePair = pair;
      this.parallaxMaterial.uniforms.uTexA.value = prev.texture;
      this.parallaxMaterial.uniforms.uTexB.value = next.texture;
      this.parallaxMaterial.uniforms.uBlend.value = eased;
      this.dirty = true;
    } else if (Math.abs((this.parallaxMaterial.uniforms.uBlend.value as number) - eased) > 0.002) {
      this.parallaxMaterial.uniforms.uBlend.value = eased;
      this.dirty = true;
    }
  }

  /* ---------- render-on-demand loop ---------- */

  private requestRender(): void {
    this.dirty = true;
    if (this.rafId === null && this.isVisible && !this.contextLost && !this.disposed) {
      this.lastTick = performance.now();
      this.rafId = requestAnimationFrame(this.tick);
    }
  }

  private stopLoop(): void {
    if (this.rafId !== null) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
  }

  private tick = (now: number): void => {
    this.rafId = null;
    if (!this.isVisible || this.contextLost) return;

    const dt = Math.min(0.05, (now - this.lastTick) / 1000 || 0.016);
    this.lastTick = now;

    const animating = this.step(dt);

    if (this.dirty) {
      this.renderer.render(this.scene, this.camera);
      this.dirty = false;
      this.updateCallouts();
    }

    if (animating) {
      this.rafId = requestAnimationFrame(this.tick);
    }
  };

  /** Advance all interpolations. Returns true while anything is still in motion. */
  private step(dt: number): boolean {
    let animating = false;

    // Mouse easing (drives parallax + light sweep)
    if (!this.mouseNorm.equals(this.targetMouseNorm)) {
      this.mouseNorm.lerp(this.targetMouseNorm, 0.08);
      this.parallaxMaterial.uniforms.uMouse.value.copy(this.mouseNorm);
      if (!this.isReducedMotion) {
        this.parallaxMaterial.uniforms.uLightSweep.value = 0.5 + this.mouseNorm.x * 0.3;
      }
      this.dirty = true;
      if (this.mouseNorm.distanceTo(this.targetMouseNorm) > 0.002) animating = true;
    }

    // Turntable inertia
    if (this.isDragging) {
      this.currentAngle = this.targetAngle;
      this.updateTurntable();
      animating = true;
    } else {
      const dAngle = this.targetAngle - this.currentAngle;
      if (Math.abs(dAngle) > 0.0008 || Math.abs(this.angularVelocity) > 0.0004) {
        this.currentAngle += dAngle * 0.1;
        this.angularVelocity *= Math.pow(0.92, dt * 60);
        this.targetAngle += this.angularVelocity;
        this.updateTurntable();
        animating = true;
      }
    }

    // Texture crossfade (enter/leave special views)
    if (this.fadeActive) {
      this.fadeWeight = Math.min(1, this.fadeWeight + dt * 3);
      const eased = this.fadeWeight * this.fadeWeight * (3 - 2 * this.fadeWeight);
      this.parallaxMaterial.uniforms.uTexA.value = this.fadeFrom;
      this.parallaxMaterial.uniforms.uTexB.value = this.fadeTo;
      this.parallaxMaterial.uniforms.uBlend.value = eased;
      this.dirty = true;
      animating = true;
      if (this.fadeWeight >= 1) {
        this.fadeActive = false;
        this.parallaxMaterial.uniforms.uTexA.value = this.fadeTo;
        this.parallaxMaterial.uniforms.uTexB.value = this.fadeTo;
        this.parallaxMaterial.uniforms.uBlend.value = 0;
        this.showingSpecial = this.specialIndex !== -1;
        this.activePair = ''; // force turntable pair refresh after leaving a special view
        this.dirty = true;
      }
    }

    // Scroll-linked dolly
    const dFrustum = this.targetFrustum - this.currentFrustum;
    if (Math.abs(dFrustum) > 0.0008) {
      this.currentFrustum += dFrustum * Math.min(1, dt * 5);
      this.applyFrustum(this.currentFrustum);
      this.dirty = true;
      animating = true;
    }

    // Wind tunnel
    const dActive = this.windActiveTarget - this.windActive;
    if (Math.abs(dActive) > 0.001) {
      this.windActive += dActive * Math.min(1, dt * 4);
      this.particleMaterial.uniforms.uActive.value = this.windActive;
      this.dirty = true;
      animating = true;
    }
    const dWind = this.targetWindSpeed - this.windSpeed;
    if (Math.abs(dWind) > 0.001) {
      this.windSpeed += dWind * Math.min(1, dt * 4);
      this.dirty = true;
      animating = true;
    }
    if (this.windActive > 0.001) {
      this.particleMaterial.uniforms.uTime.value += dt;
      this.particleMaterial.uniforms.uWindSpeed.value = this.windSpeed;
      this.dirty = true;
      animating = true;
    }

    // Night-mode headlight glow
    const dGlow = this.glowTarget - this.glowIntensity;
    if (Math.abs(dGlow) > 0.002) {
      this.glowIntensity += dGlow * Math.min(1, dt * 2.5);
      this.dirty = true;
      animating = true;
    }
    if (this.glowIntensity > 0.002) {
      this.updateNightLighting();
    } else if ((this.noseGlow.material as THREE.MeshBasicMaterial).opacity !== 0) {
      (this.noseGlow.material as THREE.MeshBasicMaterial).opacity = 0;
      (this.lightPool.material as THREE.MeshBasicMaterial).opacity = 0;
      this.dirty = true;
    }

    return animating;
  }

  private updateNightLighting(): void {
    if (this.specialIndex !== -1 || this.fadeActive) {
      const glowMat = this.noseGlow.material as THREE.MeshBasicMaterial;
      const poolMat = this.lightPool.material as THREE.MeshBasicMaterial;
      if (glowMat.opacity !== 0 || poolMat.opacity !== 0) {
        glowMat.opacity = 0;
        poolMat.opacity = 0;
        this.dirty = true;
      }
      return;
    }

    // Anchor the glow to the nose of whichever frame is dominant
    let best: TurntableFrame | null = null;
    let bestDiff = Infinity;
    for (const frame of this.frames) {
      if (!(frame.id in this.noseAnchors) || !frame.texture) continue;
      let diff = Math.abs(this.currentAngle - frame.angle) % TWO_PI;
      if (diff > Math.PI) diff = TWO_PI - diff;
      if (diff < bestDiff) {
        bestDiff = diff;
        best = frame;
      }
    }

    const glowMat = this.noseGlow.material as THREE.MeshBasicMaterial;
    const poolMat = this.lightPool.material as THREE.MeshBasicMaterial;

    if (!best || bestDiff > 0.5) {
      glowMat.opacity = 0;
      poolMat.opacity = 0;
      this.dirty = true;
      return;
    }

    const anchor = this.noseAnchors[best.id]!;
    const angleFade = Math.max(0, 1 - bestDiff / 0.5);
    const intensity = this.glowIntensity * angleFade;

    this.noseGlow.position.set(
      (anchor.u - 0.5) * PLANE_W + this.carPlaneMesh.position.x,
      (anchor.v - 0.5) * PLANE_H + this.carPlaneMesh.position.y,
      0.4,
    );
    const noseWorldX = (anchor.u - 0.5) * PLANE_W;
    this.lightPool.position.x = noseWorldX * 0.9;

    glowMat.opacity = 0.42 * intensity;
    poolMat.opacity = 0.3 * intensity;
    this.dirty = true;
  }

  /* ---------- visibility + resize ---------- */

  private setupObserver(): void {
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          this.isVisible = entry.isIntersecting;
          if (this.isVisible) {
            this.onScroll?.();
            this.requestRender();
          } else {
            this.stopLoop();
          }
        });
      },
      { threshold: 0.1 },
    );
    observer.observe(this.container);
  }

  private onResize(): void {
    const width = this.container.clientWidth;
    const height = this.container.clientHeight;
    if (width === 0 || height === 0) return;
    this.renderer.setSize(width, height);
    this.particleMaterial.uniforms.uPixelRatio.value = Math.min(window.devicePixelRatio || 1, 2);
    this.applyFrustum(this.currentFrustum);
    this.dirty = true;
  }

  public dispose(): void {
    this.disposed = true;
    this.stopLoop();
    this.resizeObserver?.disconnect();
    this.themeObserver?.disconnect();
    this.mediaQuery?.removeEventListener?.('change', this.onThemeMedia!);
    if (this.onScroll) window.removeEventListener('scroll', this.onScroll);
    if (this.onVisChange) document.removeEventListener('visibilitychange', this.onVisChange);
    this.scene.traverse((obj) => {
      const mesh = obj as THREE.Mesh;
      if (mesh.geometry) mesh.geometry.dispose();
      const mat = mesh.material as THREE.Material | THREE.Material[] | undefined;
      if (Array.isArray(mat)) mat.forEach((m) => m.dispose());
      else mat?.dispose();
    });
    this.renderer.dispose();
    this.canvas.remove();
    for (const c of this.callouts) c.el.remove();
  }
}
