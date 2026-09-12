/**
 * @file ThreeTabInspector.ts
 * @description Holographic 3D automotive telemetry inspector and interactive sensor visor for Hisingen native features.
 * @author Nico <nicolas.kheirallah@gmail.com>
 * @version 1.0.0
 */

import * as THREE from 'three';

export type InspectorTab = 'vehicle' | 'controls' | 'history' | 'diagnostics' | 'preferences';

export class ThreeTabInspector {
  private container: HTMLElement;
  private canvas: HTMLCanvasElement;
  private scene: THREE.Scene;
  private camera: THREE.PerspectiveCamera;
  private renderer: THREE.WebGLRenderer;
  private clock: THREE.Clock;
  private animId: number | null = null;
  private isVisible = true;
  private isDestroyed = false;

  // 3D Objects
  private carGroup: THREE.Group;
  private gridHelper: THREE.GridHelper;
  private beacons: Map<string, THREE.Group> = new Map();
  private hvacParticles: THREE.Points | null = null;
  private chargingSpline: THREE.Line | null = null;
  private batteryCellsGroup: THREE.Group = new THREE.Group();
  private hudPlane: THREE.LineSegments | null = null;

  // Interaction & Camera State
  private targetCameraPos = new THREE.Vector3(0, 7, 24);
  private targetLookAt = new THREE.Vector3(0, 0.5, 0);
  private currentLookAt = new THREE.Vector3(0, 0.5, 0);
  private activeTab: InspectorTab = 'vehicle';
  private activeNodeId: string | null = null;
  private isDragging = false;
  private prevMouseX = 0;
  private prevMouseY = 0;
  private orbitAngleX = 0.25;
  private orbitAngleY = 0.35;
  private targetOrbitX = 0.25;
  private targetOrbitY = 0.35;

  // Hud readout element
  private hudReadoutEl: HTMLElement | null = null;

  constructor(containerId: string) {
    const el = document.getElementById(containerId);
    if (!el) {
      throw new Error(`ThreeTabInspector: Element #${containerId} not found`);
    }
    this.container = el;

    this.canvas = document.createElement('canvas');
    this.canvas.className = 'tab-inspector-canvas';
    this.container.appendChild(this.canvas);

    this.hudReadoutEl = this.container.querySelector('.inspector-hud-readout');

    this.scene = new THREE.Scene();
    this.clock = new THREE.Clock();

    const rect = this.container.getBoundingClientRect();
    const width = rect.width || 600;
    const height = rect.height || 360;

    this.camera = new THREE.PerspectiveCamera(42, width / height, 0.1, 100);
    this.camera.position.copy(this.targetCameraPos);

    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      antialias: true,
      alpha: true,
      powerPreference: 'high-performance',
    });
    this.renderer.setSize(width, height);
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));

    this.carGroup = new THREE.Group();
    this.scene.add(this.carGroup);

    // Floor Grid
    this.gridHelper = new THREE.GridHelper(30, 30, 0xd4af37, 0x22262e);
    this.gridHelper.position.y = -1.2;
    this.scene.add(this.gridHelper);

    // Build procedural 3D wireframe car & systems
    this.buildChassis();
    this.buildSensors();
    this.buildHvacSystem();
    this.buildChargingSpline();
    this.buildBatteryPack();
    this.buildHudPlanes();

    this.setupLights();
    this.setupEvents();
    this.setTab('vehicle');

    this.animate();
  }

  private setupLights(): void {
    const ambient = new THREE.AmbientLight(0xffffff, 0.8);
    this.scene.add(ambient);

    const goldRim = new THREE.DirectionalLight(0xd4af37, 2.5);
    goldRim.position.set(10, 15, 10);
    this.scene.add(goldRim);

    const cyanRim = new THREE.DirectionalLight(0x00e5ff, 2.0);
    cyanRim.position.set(-10, 10, -10);
    this.scene.add(cyanRim);
  }

  private buildChassis(): void {
    // Holographic silhouette curves (Fastback EV shape)
    const bodyMat = new THREE.LineBasicMaterial({
      color: 0xd4af37,
      transparent: true,
      opacity: 0.75,
      linewidth: 1.5,
    });

    const roofCurve = new THREE.CatmullRomCurve3([
      new THREE.Vector3(0, 0.2, 5.8),   // Front bumper
      new THREE.Vector3(0, 0.6, 4.8),   // Hood front
      new THREE.Vector3(0, 1.3, 2.8),   // Windshield base
      new THREE.Vector3(0, 2.3, 0.5),   // Windshield top
      new THREE.Vector3(0, 2.3, -1.2),  // Roof rear
      new THREE.Vector3(0, 1.4, -3.8),  // Rear fastback glass
      new THREE.Vector3(0, 0.9, -5.4),  // Tailgate edge
      new THREE.Vector3(0, 0.1, -5.6),  // Rear bumper
    ]);

    const roofPoints = roofCurve.getPoints(50);
    const roofGeom = new THREE.BufferGeometry().setFromPoints(roofPoints);
    const roofLine = new THREE.Line(roofGeom, bodyMat);
    this.carGroup.add(roofLine);

    // Left & Right Beltlines
    [-1.7, 1.7].forEach((side) => {
      const beltCurve = new THREE.CatmullRomCurve3([
        new THREE.Vector3(side * 0.7, 0.2, 5.6),
        new THREE.Vector3(side * 0.95, 0.6, 3.8),
        new THREE.Vector3(side * 1.0, 0.9, 1.5),
        new THREE.Vector3(side * 1.0, 0.9, -2.0),
        new THREE.Vector3(side * 0.95, 0.9, -4.2),
        new THREE.Vector3(side * 0.7, 0.5, -5.4),
      ]);
      const beltLine = new THREE.Line(new THREE.BufferGeometry().setFromPoints(beltCurve.getPoints(40)), bodyMat);
      this.carGroup.add(beltLine);
    });

    // 4 Wheels
    const wheelGeom = new THREE.RingGeometry(0.55, 0.75, 24);
    const wheelMat = new THREE.MeshBasicMaterial({
      color: 0x64d2ff,
      wireframe: true,
      side: THREE.DoubleSide,
      transparent: true,
      opacity: 0.6,
    });

    const wheelPositions = [
      { x: -1.75, y: -0.4, z: 3.4 },   // Front Left
      { x: 1.75, y: -0.4, z: 3.4 },    // Front Right
      { x: -1.75, y: -0.4, z: -3.2 },  // Rear Left
      { x: 1.75, y: -0.4, z: -3.2 },   // Rear Right
    ];

    wheelPositions.forEach((pos) => {
      const wheel = new THREE.Mesh(wheelGeom, wheelMat);
      wheel.position.set(pos.x, pos.y, pos.z);
      wheel.rotation.y = Math.PI / 2;
      this.carGroup.add(wheel);
    });
  }

  private createBeacon(id: string, pos: THREE.Vector3, color: number, label: string): void {
    const group = new THREE.Group();
    group.position.copy(pos);

    // Inner glowing sphere
    const sphereGeom = new THREE.SphereGeometry(0.18, 16, 16);
    const sphereMat = new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.9 });
    const sphere = new THREE.Mesh(sphereGeom, sphereMat);
    group.add(sphere);

    // Pulsing outer ring
    const ringGeom = new THREE.RingGeometry(0.24, 0.38, 24);
    const ringMat = new THREE.MeshBasicMaterial({
      color,
      side: THREE.DoubleSide,
      transparent: true,
      opacity: 0.7,
    });
    const ring = new THREE.Mesh(ringGeom, ringMat);
    ring.rotation.x = Math.PI / 2;
    ring.name = 'pulseRing';
    group.add(ring);

    group.userData = { id, label, defaultColor: color };
    this.beacons.set(id, group);
    this.carGroup.add(group);
  }

  private buildSensors(): void {
    // 4 TPMS Beacons
    this.createBeacon('tpms_fl', new THREE.Vector3(-1.9, -0.3, 3.4), 0x30d158, 'FL Tyre · 250 kPa');
    this.createBeacon('tpms_fr', new THREE.Vector3(1.9, -0.3, 3.4), 0x30d158, 'FR Tyre · 250 kPa');
    this.createBeacon('tpms_rl', new THREE.Vector3(-1.9, -0.3, -3.2), 0x30d158, 'RL Tyre · 250 kPa');
    this.createBeacon('tpms_rr', new THREE.Vector3(1.9, -0.3, -3.2), 0x30d158, 'RR Tyre · 250 kPa');

    // Charge Port Beacon (Rear Left)
    this.createBeacon('charge_port', new THREE.Vector3(-1.8, 0.6, -3.8), 0x00e5ff, '3-Phase AC/DC · 11.2 kW');

    // 12V Auxiliary Battery (Front Hood)
    this.createBeacon('aux_battery', new THREE.Vector3(0, 0.4, 4.4), 0xffd60a, '12V Aux Battery · 14.1 V (Good)');

    // Cabin Air Quality / HVAC
    this.createBeacon('cabin_aqi', new THREE.Vector3(0, 1.3, 0.2), 0x30d158, 'CleanZone · PM2.5 = 1 µg/m³');

    // Vehicle GPS / Map Beacon
    this.createBeacon('gps_loc', new THREE.Vector3(0, 2.4, -0.5), 0xff9f0a, 'GPS Antenna · Locked (±3m)');

    // 4 Door Latches
    this.createBeacon('door_fl', new THREE.Vector3(-1.8, 0.8, 1.2), 0x64d2ff, 'Front Left Door · Closed');
    this.createBeacon('door_fr', new THREE.Vector3(1.8, 0.8, 1.2), 0x64d2ff, 'Front Right Door · Closed');
    this.createBeacon('door_rl', new THREE.Vector3(-1.8, 0.8, -1.0), 0x64d2ff, 'Rear Left Door · Closed');
    this.createBeacon('door_rr', new THREE.Vector3(1.8, 0.8, -1.0), 0x64d2ff, 'Rear Right Door · Closed');
  }

  private buildHvacSystem(): void {
    // Convection particle cloud inside cabin
    const count = 120;
    const geom = new THREE.BufferGeometry();
    const positions = new Float32Array(count * 3);
    const colors = new Float32Array(count * 3);

    const warmColor = new THREE.Color(0xff9f0a);
    const coolColor = new THREE.Color(0x64d2ff);

    for (let i = 0; i < count; i++) {
      const idx = i * 3;
      positions[idx] = (Math.random() - 0.5) * 2.2;
      positions[idx + 1] = 0.5 + Math.random() * 1.4;
      positions[idx + 2] = -1.8 + Math.random() * 3.4;

      const mix = Math.random();
      const col = warmColor.clone().lerp(coolColor, mix);
      colors[idx] = col.r;
      colors[idx + 1] = col.g;
      colors[idx + 2] = col.b;
    }

    geom.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geom.setAttribute('color', new THREE.BufferAttribute(colors, 3));

    const mat = new THREE.PointsMaterial({
      size: 0.16,
      vertexColors: true,
      transparent: true,
      opacity: 0.7,
      blending: THREE.AdditiveBlending,
    });

    this.hvacParticles = new THREE.Points(geom, mat);
    this.hvacParticles.visible = false;
    this.carGroup.add(this.hvacParticles);
  }

  private buildChargingSpline(): void {
    // 3D Charging Power Curve Spline
    const points = [
      new THREE.Vector3(-1.8, 0.6, -3.8),
      new THREE.Vector3(-3.0, 2.0, -2.5),
      new THREE.Vector3(-3.5, 3.5, 0.0),
      new THREE.Vector3(-2.8, 4.8, 2.5),
      new THREE.Vector3(0.0, 5.5, 4.0),
    ];
    const curve = new THREE.CatmullRomCurve3(points);
    const geom = new THREE.BufferGeometry().setFromPoints(curve.getPoints(50));
    const mat = new THREE.LineBasicMaterial({
      color: 0x30d158,
      transparent: true,
      opacity: 0.8,
      linewidth: 2,
    });

    this.chargingSpline = new THREE.Line(geom, mat);
    this.chargingSpline.visible = false;
    this.carGroup.add(this.chargingSpline);
  }

  private buildBatteryPack(): void {
    // Underbody modular battery cell matrix
    const rows = 4;
    const cols = 8;
    const cellGeom = new THREE.BoxGeometry(0.35, 0.12, 0.65);
    const cellMat = new THREE.MeshBasicMaterial({
      color: 0x30d158,
      wireframe: true,
      transparent: true,
      opacity: 0.5,
    });

    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const cell = new THREE.Mesh(cellGeom, cellMat);
        cell.position.set(-1.0 + r * 0.65, -0.65, -2.2 + c * 0.7);
        this.batteryCellsGroup.add(cell);
      }
    }
    this.batteryCellsGroup.visible = false;
    this.carGroup.add(this.batteryCellsGroup);
  }

  private buildHudPlanes(): void {
    // Floating HUD Alignment Guides
    const geom = new THREE.BufferGeometry();
    const verts = new Float32Array([
      -5, -1.2, 6,  5, -1.2, 6,
      -5, -1.2, -6, 5, -1.2, -6,
      -5, -1.2, 6, -5, -1.2, -6,
       5, -1.2, 6,  5, -1.2, -6,
    ]);
    geom.setAttribute('position', new THREE.BufferAttribute(verts, 3));
    const mat = new THREE.LineBasicMaterial({ color: 0xd4af37, transparent: true, opacity: 0.35 });
    this.hudPlane = new THREE.LineSegments(geom, mat);
    this.scene.add(this.hudPlane);
  }

  private setupEvents(): void {
    window.addEventListener('resize', this.onResize);

    this.canvas.addEventListener('mousedown', (e) => {
      this.isDragging = true;
      this.prevMouseX = e.clientX;
      this.prevMouseY = e.clientY;
    });

    window.addEventListener('mousemove', (e) => {
      if (!this.isDragging) return;
      const dx = e.clientX - this.prevMouseX;
      const dy = e.clientY - this.prevMouseY;
      this.targetOrbitX += dx * 0.006;
      this.targetOrbitY = Math.max(0.1, Math.min(1.2, this.targetOrbitY + dy * 0.006));
      this.prevMouseX = e.clientX;
      this.prevMouseY = e.clientY;
    });

    window.addEventListener('mouseup', () => {
      this.isDragging = false;
    });

    // Touch support
    this.canvas.addEventListener('touchstart', (e) => {
      if (e.touches.length === 1) {
        this.isDragging = true;
        this.prevMouseX = e.touches[0].clientX;
        this.prevMouseY = e.touches[0].clientY;
      }
    }, { passive: true });

    window.addEventListener('touchmove', (e) => {
      if (!this.isDragging || e.touches.length !== 1) return;
      const dx = e.touches[0].clientX - this.prevMouseX;
      const dy = e.touches[0].clientY - this.prevMouseY;
      this.targetOrbitX += dx * 0.008;
      this.targetOrbitY = Math.max(0.1, Math.min(1.2, this.targetOrbitY + dy * 0.008));
      this.prevMouseX = e.touches[0].clientX;
      this.prevMouseY = e.touches[0].clientY;
    }, { passive: true });

    window.addEventListener('touchend', () => {
      this.isDragging = false;
    });

    // Intersection observer for performance
    const observer = new IntersectionObserver(([entry]) => {
      this.isVisible = entry.isIntersecting;
    }, { threshold: 0.1 });
    observer.observe(this.container);
  }

  private onResize = (): void => {
    if (this.isDestroyed) return;
    const rect = this.container.getBoundingClientRect();
    const width = rect.width || 600;
    const height = rect.height || 360;
    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(width, height);
  };

  public setTab(tab: InspectorTab): void {
    this.activeTab = tab;

    // Reset visibility of specific systems
    if (this.hvacParticles) this.hvacParticles.visible = tab === 'controls';
    if (this.chargingSpline) this.chargingSpline.visible = tab === 'history';
    if (this.batteryCellsGroup) this.batteryCellsGroup.visible = tab === 'diagnostics' || tab === 'vehicle';

    // Highlight preset camera angles per tab
    switch (tab) {
      case 'vehicle':
        this.targetCameraPos.set(0, 6, 20);
        this.targetLookAt.set(0, 0, 0);
        this.updateHud('[ CAN-BUS TELEMETRY ACTIVE · 12 SYSTEM CHANNELS ]');
        break;
      case 'controls':
        this.targetCameraPos.set(-12, 8, 14);
        this.targetLookAt.set(0, 1.0, 0);
        this.updateHud('[ CLIMATE & BIOMETRIC GATEWAY · READY ]');
        break;
      case 'history':
        this.targetCameraPos.set(-16, 12, -8);
        this.targetLookAt.set(0, 0.5, 0);
        this.updateHud('[ CHARGING CURVE ARCHIVE & TARIFF ENGINE ]');
        break;
      case 'diagnostics':
        this.targetCameraPos.set(0, 14, 12);
        this.targetLookAt.set(0, -0.5, 0);
        this.updateHud('[ BATTERY SOH: 98.4% · 400V PACK HEALTH CHECK ]');
        break;
      case 'preferences':
        this.targetCameraPos.set(14, 8, 16);
        this.targetLookAt.set(0, 0, 0);
        this.updateHud('[ MACOS PREFERENCES & 120HZ PROMOTION SYNC ]');
        break;
    }
  }

  public highlightNode(nodeId: string | null): void {
    this.activeNodeId = nodeId;
    if (!nodeId) {
      this.setTab(this.activeTab);
      return;
    }

    // Match node to beacon
    const beacon = this.beacons.get(nodeId);
    if (beacon) {
      this.targetLookAt.copy(beacon.position);
      this.updateHud(`[ SUBSYSTEM FOCUS: ${beacon.userData.label} ]`);
    } else if (nodeId === 'battery') {
      this.targetCameraPos.set(0, 10, 10);
      this.targetLookAt.set(0, -0.6, 0);
      this.updateHud('[ SUBSYSTEM FOCUS: High-Voltage Battery Pack & SoH ]');
    } else if (nodeId === 'climate') {
      this.targetCameraPos.set(0, 5, 8);
      this.targetLookAt.set(0, 1.2, 0);
      this.updateHud('[ SUBSYSTEM FOCUS: Cabin HVAC & PM2.5 CleanZone ]');
    } else if (nodeId === 'charging') {
      this.targetCameraPos.set(-8, 4, -8);
      this.targetLookAt.set(-1.8, 0.6, -3.8);
      this.updateHud('[ SUBSYSTEM FOCUS: 3-Phase AC/DC Fast Charging Port ]');
    }
  }

  private updateHud(text: string): void {
    if (this.hudReadoutEl) {
      this.hudReadoutEl.textContent = text;
    }
  }

  public setTheme(isDark: boolean): void {
    this.gridHelper.material = new THREE.LineBasicMaterial({
      color: isDark ? 0x22262e : 0xd8d4cb,
    });
  }

  private animate = (): void => {
    if (this.isDestroyed) return;
    this.animId = requestAnimationFrame(this.animate);

    if (!this.isVisible) return;

    const delta = this.clock.getDelta();
    const elapsedTime = this.clock.getElapsedTime();

    // Smooth Orbit & Camera Movement
    this.orbitAngleX += (this.targetOrbitX - this.orbitAngleX) * delta * 4;
    this.orbitAngleY += (this.targetOrbitY - this.orbitAngleY) * delta * 4;

    this.carGroup.rotation.y = this.orbitAngleX;
    this.carGroup.rotation.x = (this.orbitAngleY - 0.35) * 0.4;

    this.currentLookAt.lerp(this.targetLookAt, delta * 3);
    this.camera.position.lerp(this.targetCameraPos, delta * 3);
    this.camera.lookAt(this.currentLookAt);

    // Pulse Beacons
    this.beacons.forEach((beacon, id) => {
      const ring = beacon.getObjectByName('pulseRing');
      if (ring) {
        const isFocused = this.activeNodeId === id;
        const scale = isFocused
          ? 1.5 + Math.sin(elapsedTime * 8) * 0.4
          : 1.0 + Math.sin(elapsedTime * 3 + beacon.position.x) * 0.2;
        ring.scale.set(scale, scale, 1);

        const mat = (ring as THREE.Mesh).material as THREE.MeshBasicMaterial;
        mat.opacity = isFocused ? 0.95 : 0.45;
      }
    });

    // Animate HVAC particles
    if (this.hvacParticles && this.hvacParticles.visible) {
      const posAttr = this.hvacParticles.geometry.getAttribute('position') as THREE.BufferAttribute;
      const arr = posAttr.array as Float32Array;
      for (let i = 0; i < arr.length / 3; i++) {
        const idx = i * 3;
        arr[idx + 1] += Math.sin(elapsedTime * 2 + i) * 0.005;
        arr[idx + 2] += Math.cos(elapsedTime * 1.5 + i) * 0.005;
      }
      posAttr.needsUpdate = true;
    }

    // Animate Battery Pack pulse
    if (this.batteryCellsGroup && this.batteryCellsGroup.visible) {
      this.batteryCellsGroup.children.forEach((cell, idx) => {
        const mesh = cell as THREE.Mesh;
        const mat = mesh.material as THREE.MeshBasicMaterial;
        mat.opacity = 0.3 + (Math.sin(elapsedTime * 3 + idx * 0.2) + 1) * 0.2;
      });
    }

    this.renderer.render(this.scene, this.camera);
  };

  public destroy(): void {
    this.isDestroyed = true;
    if (this.animId) cancelAnimationFrame(this.animId);
    window.removeEventListener('resize', this.onResize);
    this.renderer.dispose();
    this.canvas.remove();
  }
}
