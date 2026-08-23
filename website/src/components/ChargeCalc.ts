export class ChargeCalc {
  private container: HTMLElement;
  private slider: HTMLInputElement | null;
  private socReadout: HTMLElement | null;
  private acDurationEl: HTMLElement | null;
  private dcDurationEl: HTMLElement | null;
  private energyEl: HTMLElement | null;
  private costEl: HTMLElement | null;

  private batteryCapacityKwh = 78;

  constructor(containerId: string) {
    const container = document.getElementById(containerId);
    if (!container) {
      this.container = document.createElement('div');
      this.slider = null;
      this.socReadout = null;
      this.acDurationEl = null;
      this.dcDurationEl = null;
      this.energyEl = null;
      this.costEl = null;
      return;
    }
    this.container = container;

    this.slider = this.container.querySelector<HTMLInputElement>('[data-calc-slider]');
    this.socReadout = this.container.querySelector<HTMLElement>('[data-calc-soc]');
    this.acDurationEl = this.container.querySelector<HTMLElement>('[data-calc-ac]');
    this.dcDurationEl = this.container.querySelector<HTMLElement>('[data-calc-dc]');
    this.energyEl = this.container.querySelector<HTMLElement>('[data-calc-energy]');
    this.costEl = this.container.querySelector<HTMLElement>('[data-calc-cost]');

    if (!this.slider) return;

    this.slider.addEventListener('input', () => this.recalculate());
    this.recalculate();
  }

  private recalculate(): void {
    if (!this.slider) return;
    const targetSoc = Number(this.slider.value);
    const startSoc = 10;
    const socDelta = Math.max(0, targetSoc - startSoc);

    const energyAddedKwh = (this.batteryCapacityKwh * socDelta) / 100;
    
    // AC 11 kW 3-phase charging time
    const acHours = energyAddedKwh / 11.0;
    const acH = Math.floor(acHours);
    const acM = Math.round((acHours - acH) * 60);

    // DC Fast Charging 205 kW curve (tapered)
    const dcMinutes = Math.max(8, Math.round((energyAddedKwh / 115.0) * 60 + 5));

    // Home electricity estimated cost (€0.22/kWh average)
    const costEur = (energyAddedKwh * 0.22).toFixed(2);

    if (this.socReadout) this.socReadout.textContent = `${targetSoc}%`;
    if (this.acDurationEl) this.acDurationEl.textContent = `${acH}h ${acM.toString().padStart(2, '0')}m`;
    if (this.dcDurationEl) this.dcDurationEl.textContent = `${dcMinutes} min`;
    if (this.energyEl) this.energyEl.textContent = `+${energyAddedKwh.toFixed(1)} kWh`;
    if (this.costEl) this.costEl.textContent = `~€${costEur}`;
  }
}
