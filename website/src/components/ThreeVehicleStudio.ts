/**
 * @file ThreeVehicleStudio.ts
 * @description  automotive studio combining authentic factory imagery with:
 * 1. 2.5D Depth Parallax & Clearcoat Specular Reflection Shader
 * 2. GPU Aerodynamic Wind Tunnel Particle Streamlines (0.278 Cd)
 * 3. 360° Multi-Frame Studio Turntable Orbit with Momentum
 */

import * as THREE from 'three';

const baseUrl = (import.meta.env?.BASE_URL || '/').replace(/\/$/, '') + '/';

export type StudioMode = 'orbit' | 'parallax' | 'windtunnel';

interface TextureFrame {
  id: string;
  name: string;
  url: string;
  angle: number; // 0 to 2pi
  texture?: THREE.Texture;
}

export class ThreeVehicleStudio {
  private container: HTMLElement;
  private canvas: HTMLCanvasElement;
  private renderer!: THREE.WebGLRenderer;
  private scene!: THREE.Scene;
  private camera!: THREE.OrthographicCamera;
  private isVisible = false;
  private animId: number | null = null;
  private clock = new THREE.Clock();

  // Mode state
  private currentMode: StudioMode = 'orbit';
  private isDark = false;
  private isReducedMotion = false;

  // Turntable Orbit State
  private frames: TextureFrame[] = [
    { id: 'front', name: 'Direct Front', url: `${baseUrl}assets/vehicle/polestar2-front.webp`, angle: 0.0 },
    { id: 'front34', name: '3/4 Front', url: `${baseUrl}assets/vehicle/polestar2-front-threequarter.webp`, angle: 0.785 },
    { id: 'side', name: 'Side Profile', url: `${baseUrl}assets/vehicle/polestar2-side-profile.webp`, angle: 1.57 },
    { id: 'rear34', name: '3/4 Rear', url: `${baseUrl}assets/vehicle/polestar2-rear-threequarter.webp`, angle: 2.356 },
    { id: 'rear', name: 'Direct Rear', url: `${baseUrl}assets/vehicle/polestar2-rear.webp`, angle: 3.141 },
    { id: 'side2', name: 'Side Profile (Flip)', url: `${baseUrl}assets/vehicle/polestar2-side-profile.webp`, angle: 4.712 },
    { id: 'front34_return', name: '3/4 Front (Return)', url: `${baseUrl}assets/vehicle/polestar2-front-threequarter.webp`, angle: 5.497 },
    { id: 'front_loop', name: 'Direct Front (Loop)', url: `${baseUrl}assets/vehicle/polestar2-front.webp`, angle: 6.283 },
  ];
  private currentAngle = 0.785; // radians (start on Front 3/4)
  private targetAngle = 0.785;
  private angularVelocity = 0;
  private isDragging = false;
  private lastPointerX = 0;
  private isSpecialView = false;
  private angleTextures: Map<number, THREE.Texture> = new Map();

  // 2.5D Parallax & Clearcoat Mesh
  private carPlaneMesh!: THREE.Mesh;
  private parallaxMaterial!: THREE.ShaderMaterial;
  private mouseNorm = new THREE.Vector2(0, 0);
  private targetMouseNorm = new THREE.Vector2(0, 0);

  // Aerodynamic Wind Tunnel Particle System
  private particleCount = 1600;
  private particleSystem!: THREE.Points;
  private particleGeometry!: THREE.BufferGeometry;
  private particleMaterial!: THREE.ShaderMaterial;
  private windSpeed = 1.0; // 1.0 = 100 km/h, 0.0 = stopped
  private targetWindSpeed = 1.0;

  // Ground Shadow Plane
  private shadowPlane!: THREE.Mesh;

  constructor(containerId: string) {
    const el = document.getElementById(containerId);
    if (!el) throw new Error(`Container #${containerId} not found`);
    this.container = el;

    this.isReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.isDark = document.documentElement.dataset.theme === 'dark' ||
      (!document.documentElement.dataset.theme && window.matchMedia('(prefers-color-scheme: dark)').matches);

    this.canvas = document.createElement('canvas');
    this.canvas.className = 'three-studio-canvas';
    this.container.appendChild(this.canvas);

    this.initScene();
    this.loadTextures();
    this.createCarMesh();
    this.createWindTunnelParticles();
    this.createGroundShadow();
    this.setupEvents();
    this.setupObserver();
    this.onResize();
  }

  private initScene(): void {
    this.scene = new THREE.Scene();
    this.camera = new THREE.OrthographicCamera(-2, 2, 1.125, -1.125, 0.1, 100);
    this.camera.position.set(0, 0, 10);
    this.camera.lookAt(0, 0, 0);

    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      alpha: true,
      antialias: true,
      powerPreference: 'high-performance',
    });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.setSize(this.container.clientWidth, this.container.clientHeight);
  }

  private loadTextures(): void {
    const loader = new THREE.TextureLoader();

    // All 8 individual vehicle angle assets
    const allAngleUrls = [
      `${baseUrl}assets/vehicle/polestar2-front-threequarter.webp`, // 0: 3/4 Front
      `${baseUrl}assets/vehicle/polestar2-front.webp`,             // 1: Front
      `${baseUrl}assets/vehicle/polestar2-side-profile.webp`,      // 2: Side
      `${baseUrl}assets/vehicle/polestar2-rear-threequarter.webp`,  // 3: 3/4 Rear
      `${baseUrl}assets/vehicle/polestar2-rear.webp`,              // 4: Rear
      `${baseUrl}assets/vehicle/polestar2-overhead.webp`,          // 5: Overhead
      `${baseUrl}assets/vehicle/polestar2-interior.webp`,          // 6: Cockpit
      `${baseUrl}assets/vehicle/polestar_outline.svg`,             // 7: CAD Wireframe
    ];

    allAngleUrls.forEach((url, idx) => {
      loader.load(url, (tex) => {
        tex.minFilter = THREE.LinearFilter;
        tex.magFilter = THREE.LinearFilter;
        tex.colorSpace = THREE.SRGBColorSpace;
        this.angleTextures.set(idx, tex);

        if (idx === 0 && this.parallaxMaterial) {
          this.parallaxMaterial.uniforms.uTextureA.value = tex;
        }
      });
    });

    this.frames.forEach((frame) => {
      loader.load(frame.url, (tex) => {
        tex.minFilter = THREE.LinearFilter;
        tex.magFilter = THREE.LinearFilter;
        tex.colorSpace = THREE.SRGBColorSpace;
        frame.texture = tex;
        if (frame.id === 'front34' && this.parallaxMaterial) {
          this.parallaxMaterial.uniforms.uTextureA.value = tex;
        }
      });
    });
  }

  private createCarMesh(): void {
    const geom = new THREE.PlaneGeometry(3.6, 2.025, 32, 32);

    const vertexShader = `
      uniform vec2 uMouse;
      uniform float uParallaxStrength;
      varying vec2 vUv;
      varying vec3 vPosition;

      void main() {
        vUv = uv;
        vec3 pos = position;

        // Subtle geometric depth curve (front/rear curve slightly into depth)
        float depthMask = sin(uv.x * 3.14159) * 0.25;
        pos.z += depthMask * 0.3;

        // Parallax shift based on mouse vector and depth
        pos.x += uMouse.x * depthMask * uParallaxStrength * 0.15;
        pos.y += uMouse.y * depthMask * uParallaxStrength * 0.08;

        vPosition = pos;
        gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
      }
    `;

    const fragmentShader = `
      uniform sampler2D uTextureA;
      uniform vec2 uMouse;
      uniform float uLightSweep;
      uniform float uIsDark;
      uniform float uSpecularIntensity;
      varying vec2 vUv;
      varying vec3 vPosition;

      void main() {
        vec4 baseColor = texture2D(uTextureA, vUv);

        if (baseColor.a < 0.02) {
          discard;
        }

        // Dynamic Clearcoat Specular Sweep
        // Simulates an elongated overhead studio light bar passing across the body
        float lightX = uLightSweep * 1.4 - 0.2;
        float distToLight = abs(vUv.x - lightX);
        float specularBar = smoothstep(0.35, 0.0, distToLight) * 0.32;

        // Moving directional highlight based on mouse offset
        vec2 lightOffset = vUv - (uMouse * 0.3 + 0.5);
        float mouseSpec = smoothstep(0.4, 0.0, length(lightOffset)) * 0.18;

        float totalSheen = (specularBar + mouseSpec) * uSpecularIntensity;
        
        // Swedish gold / crisp highlight tint
        vec3 highlightColor = mix(vec3(1.0, 1.0, 1.0), vec3(0.95, 0.82, 0.65), 0.35);
        vec3 finalRgb = baseColor.rgb + highlightColor * totalSheen * baseColor.a;

        gl_FragColor = vec4(finalRgb, baseColor.a);
      }
    `;

    this.parallaxMaterial = new THREE.ShaderMaterial({
      vertexShader,
      fragmentShader,
      uniforms: {
        uTextureA: { value: null },
        uMouse: { value: new THREE.Vector2(0, 0) },
        uParallaxStrength: { value: 1.0 },
        uLightSweep: { value: 0.5 },
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

  private createGroundShadow(): void {
    const geom = new THREE.PlaneGeometry(3.4, 0.65);
    const canvas = document.createElement('canvas');
    canvas.width = 256;
    canvas.height = 64;
    const ctx = canvas.getContext('2d')!;
    const grad = ctx.createRadialGradient(128, 32, 10, 128, 32, 120);
    grad.addColorStop(0, 'rgba(0, 0, 0, 0.45)');
    grad.addColorStop(0.5, 'rgba(0, 0, 0, 0.18)');
    grad.addColorStop(1, 'rgba(0, 0, 0, 0)');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, 256, 64);

    const shadowTex = new THREE.CanvasTexture(canvas);
    const mat = new THREE.MeshBasicMaterial({
      map: shadowTex,
      transparent: true,
      opacity: this.isDark ? 0.75 : 0.4,
      depthWrite: false,
    });

    this.shadowPlane = new THREE.Mesh(geom, mat);
    this.shadowPlane.position.set(0, -0.68, -0.1);
    this.scene.add(this.shadowPlane);
  }

  private createWindTunnelParticles(): void {
    this.particleCount = 1600;
    this.particleGeometry = new THREE.BufferGeometry();
    const positions = new Float32Array(this.particleCount * 3);
    const speeds = new Float32Array(this.particleCount);
    const offsets = new Float32Array(this.particleCount);
    const layers = new Float32Array(this.particleCount);

    for (let i = 0; i < this.particleCount; i++) {
      // 14 distinct aerodynamic probe streamline bands
      const band = Math.floor(Math.random() * 14);
      const baseY = -0.58 + band * 0.11; // -0.58 to 0.85

      positions[i * 3 + 0] = -2.2 + Math.random() * 4.4; // X
      positions[i * 3 + 1] = baseY + (Math.random() - 0.5) * 0.03; // Y
      positions[i * 3 + 2] = (Math.random() - 0.5) * 0.3; // Z

      speeds[i] = 0.95 + Math.random() * 0.35;
      offsets[i] = Math.random() * 100;
      layers[i] = band / 13.0; // 0 (underbody) to 1 (high free-stream)
    }

    this.particleGeometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    this.particleGeometry.setAttribute('aSpeed', new THREE.BufferAttribute(speeds, 1));
    this.particleGeometry.setAttribute('aOffset', new THREE.BufferAttribute(offsets, 1));
    this.particleGeometry.setAttribute('aLayer', new THREE.BufferAttribute(layers, 1));

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

        // WIND DIRECTION: Right to Left (from front nose at +1.38 to rear tail at -1.35)
        float flowX = 2.2 - mod((uTime * aSpeed * uWindSpeed * 1.55) + aOffset, 4.4);
        pos.x = flowX;

        // Exact Polestar 2 Silhouette Deflection (Normalized Front 1.38 -> Rear -1.35)
        float u = (1.38 - pos.x) / 2.73; // 0.0 at front nose, 1.0 at rear tail

        if (pos.y > -0.38) {
          // UPPER BODY STREAMLINES
          if (u >= 0.0 && u <= 1.0) {
            // Front splitter & low hood ramp (u: 0.0 -> 0.30)
            float hoodRamp = smoothstep(0.0, 0.30, u) * 0.20;
            // Windshield rake & panoramic roof arch (u: 0.25 -> 0.75, apex at u = 0.55)
            float roofPeak = sin(smoothstep(0.20, 0.80, u) * 3.14159) * 0.36;
            // Fastback taper to rear light blade (u: 0.70 -> 1.0)
            float fastbackTaper = smoothstep(0.70, 1.0, u) * -0.14;

            float upperFlow = (hoodRamp + roofPeak + fastbackTaper);
            float heightWeight = smoothstep(-0.35, 0.8, pos.y);
            pos.y += upperFlow * (0.35 + aLayer * 0.65) * heightWeight;
          } else if (u > 1.0) {
            // Downstream low-drag wake detachment
            float wakeDecay = exp(-(u - 1.0) * 1.6) * 0.12;
            float turbulence = sin(uTime * 6.0 + aOffset) * 0.015 * smoothstep(1.0, 1.8, u);
            pos.y += (wakeDecay + turbulence) * smoothstep(-0.35, 0.6, pos.y);
          }
        } else {
          // UNDERBODY GROUND EFFECT (Flat floor battery skateboard -> Rear diffuser)
          if (u >= 0.70 && u <= 1.1) {
            // Rear diffuser upward expansion
            float diffuser = smoothstep(0.70, 1.0, u) * 0.06;
            pos.y += diffuser;
          }
        }

        // Boundary edge opacity fading
        float edgeFade = smoothstep(2.2, 1.8, pos.x) * smoothstep(-2.2, -1.8, pos.x);
        vAlpha = edgeFade * (0.45 + aLayer * 0.45) * uActive;

        // Color mapping: Aero Cyan (fast stream) to Swedish Gold (boundary skin layer)
        vec3 aeroCyan = vec3(0.15, 0.85, 1.0);
        vec3 swedishGold = vec3(0.96, 0.78, 0.48);
        vec3 coldWhite = vec3(0.85, 0.95, 1.0);

        if (aLayer < 0.25) {
          vColor = mix(coldWhite, aeroCyan, aLayer * 4.0);
        } else if (aLayer < 0.65) {
          vColor = aeroCyan;
        } else {
          vColor = mix(aeroCyan, swedishGold, (aLayer - 0.65) / 0.35);
        }

        vec4 mvPosition = modelViewMatrix * vec4(pos, 1.0);
        gl_PointSize = (1.9 + aLayer * 1.8) * uPixelRatio * uActive;
        gl_Position = projectionMatrix * mvPosition;
      }
    `;

    const fragmentShader = `
      varying float vAlpha;
      varying vec3 vColor;

      void main() {
        if (vAlpha < 0.02) discard;
        vec2 coord = gl_PointCoord - vec2(0.5);
        float dist = length(coord);
        if (dist > 0.5) discard;
        float soft = smoothstep(0.5, 0.05, dist);
        gl_FragColor = vec4(vColor, vAlpha * soft * 0.75);
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
      },
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });

    this.particleSystem = new THREE.Points(this.particleGeometry, this.particleMaterial);
    this.particleSystem.position.set(0, 0, 0.2);
    this.scene.add(this.particleSystem);
  }

  private setupEvents(): void {
    // Pointer drag for 360 orbit
    const onPointerDown = (e: PointerEvent): void => {
      this.isDragging = true;
      this.isSpecialView = false;
      if (this.shadowPlane) this.shadowPlane.visible = true;
      this.lastPointerX = e.clientX;
      this.angularVelocity = 0;
      this.canvas.setPointerCapture(e.pointerId);
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
    };

    const onPointerUp = (e: PointerEvent): void => {
      this.isDragging = false;
      try {
        this.canvas.releasePointerCapture(e.pointerId);
      } catch {
        // pointer release safe
      }
    };

    this.canvas.addEventListener('pointerdown', onPointerDown);
    this.canvas.addEventListener('pointermove', onPointerMove, { passive: true });
    this.canvas.addEventListener('pointerup', onPointerUp);
    this.canvas.addEventListener('pointercancel', onPointerUp);

    window.addEventListener('resize', () => this.onResize(), { passive: true });
  }

  public setMode(mode: StudioMode): void {
    this.currentMode = mode;
    if (mode === 'windtunnel') {
      this.targetWindSpeed = 1.2;
      this.particleMaterial.uniforms.uActive.value = 1.0;
      // In wind tunnel mode, switch view to side profile
      this.targetAngle = 1.57;
      this.currentAngle = 1.57;
      this.updateTurntableBlending();
    } else {
      this.particleMaterial.uniforms.uActive.value = 0.0;
      if (mode === 'parallax') {
        this.targetAngle = 0.785; // 3/4 Front
        this.currentAngle = 0.785;
        this.updateTurntableBlending();
      }
    }
  }

  public setWindSpeed(speed: number): void {
    this.targetWindSpeed = Math.max(0, Math.min(2.5, speed));
  }

  public setAngleIndex(index: number): void {
    // 0: 3/4 Front, 1: Front, 2: Side, 3: 3/4 Rear, 4: Rear, 5: Overhead, 6: Cockpit, 7: CAD Wireframe
    if (index === 5 || index === 6 || index === 7) {
      this.isSpecialView = true;
      const tex = this.angleTextures.get(index);
      if (tex && this.parallaxMaterial) {
        this.parallaxMaterial.uniforms.uTextureA.value = tex;
      }
      if (this.shadowPlane) {
        this.shadowPlane.visible = index === 5;
      }
      return;
    }

    this.isSpecialView = false;
    if (this.shadowPlane) this.shadowPlane.visible = true;

    const angleMap = [0.785, 0.0, 1.57, 2.356, 3.141];
    if (index >= 0 && index < angleMap.length) {
      this.targetAngle = angleMap[index];
      this.currentAngle = angleMap[index];
      this.angularVelocity = 0;
      this.updateTurntableBlending();
    }
  }

  public setTheme(isDark: boolean): void {
    this.isDark = isDark;
    if (this.parallaxMaterial) {
      this.parallaxMaterial.uniforms.uIsDark.value = isDark ? 1.0 : 0.0;
    }
    if (this.shadowPlane) {
      (this.shadowPlane.material as THREE.MeshBasicMaterial).opacity = isDark ? 0.75 : 0.4;
    }
  }

  private updateTurntableBlending(): void {
    if (this.isSpecialView) return;

    const twoPi = Math.PI * 2;
    let normAngle = ((this.currentAngle % twoPi) + twoPi) % twoPi;

    // Find the closest frame
    let closestFrame = this.frames[0];
    let minDiff = Infinity;

    for (let i = 0; i < this.frames.length; i++) {
      let diff = Math.abs(normAngle - this.frames[i].angle);
      if (diff > Math.PI) diff = twoPi - diff;
      if (diff < minDiff) {
        minDiff = diff;
        closestFrame = this.frames[i];
      }
    }

    if (closestFrame.texture && this.parallaxMaterial.uniforms.uTextureA.value !== closestFrame.texture) {
      this.parallaxMaterial.uniforms.uTextureA.value = closestFrame.texture;
    }
  }

  private onResize(): void {
    const width = this.container.clientWidth;
    const height = this.container.clientHeight;
    if (width === 0 || height === 0) return;

    this.renderer.setSize(width, height);
    const aspect = width / height;

    const frustumHeight = 2.15;
    const frustumWidth = frustumHeight * aspect;

    this.camera.left = -frustumWidth / 2;
    this.camera.right = frustumWidth / 2;
    this.camera.top = frustumHeight / 2;
    this.camera.bottom = -frustumHeight / 2;
    this.camera.updateProjectionMatrix();
  }

  private setupObserver(): void {
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          this.isVisible = entry.isIntersecting;
          if (this.isVisible && !this.animId) {
            this.start();
          }
        });
      },
      { threshold: 0.1 }
    );
    observer.observe(this.container);
  }

  public getMode(): StudioMode {
    return this.currentMode;
  }

  private start(): void {
    const tick = (): void => {
      if (!this.isVisible) {
        this.animId = null;
        return;
      }

      const elapsed = this.clock.getElapsedTime();

      // Smooth mouse interpolation (disable parallax if reduced motion)
      if (!this.isReducedMotion) {
        this.mouseNorm.lerp(this.targetMouseNorm, 0.08);
        this.parallaxMaterial.uniforms.uMouse.value.copy(this.mouseNorm);
      }

      // Smooth angle inertia
      if (!this.isDragging) {
        this.currentAngle += (this.targetAngle - this.currentAngle) * 0.1;
        this.angularVelocity *= 0.92;
        this.targetAngle += this.angularVelocity;
      } else {
        this.currentAngle = this.targetAngle;
      }

      this.updateTurntableBlending();

      // Clearcoat light sweep oscillation
      const sweep = this.isReducedMotion ? 0.5 : (Math.sin(elapsed * 0.8) + 1.0) * 0.5;
      this.parallaxMaterial.uniforms.uLightSweep.value = sweep;

      // Wind Tunnel particle updates
      this.windSpeed += (this.targetWindSpeed - this.windSpeed) * 0.08;
      this.particleMaterial.uniforms.uTime.value = elapsed;
      this.particleMaterial.uniforms.uWindSpeed.value = this.windSpeed;

      this.renderer.render(this.scene, this.camera);
      this.animId = requestAnimationFrame(tick);
    };

    this.animId = requestAnimationFrame(tick);
  }
}
