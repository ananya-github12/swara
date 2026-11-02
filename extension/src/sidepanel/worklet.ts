// @ts-nocheck
/*
 * This file deliberately uses browser-valid JavaScript despite its .ts
 * extension. Vite serves `new URL('./worklet.ts', import.meta.url)` as an
 * asset, so the AudioWorklet module must not depend on the main bundle's
 * TypeScript transform.
 *
 * Captures microphone audio as 16 kHz s16le PCM, the only format Sarvam's
 * streaming recogniser accepts.
 *
 * The AudioContext is created at 16 kHz, so normally there is nothing to
 * resample here and this only converts Float32 to Int16. If the browser
 * refuses that rate and gives us its native one, we decimate by AVERAGING
 * each output sample over the input window it spans.
 *
 * The averaging matters. An earlier version interpolated between two
 * neighbouring samples, which is point sampling with extra steps: it applies
 * no low-pass filter, so everything above 8 kHz aliases back down into the
 * speech band. The recogniser hears that as mangled consonants and words
 * nobody said. A box filter is crude, but it is a real filter, and it is the
 * difference between usable and unusable audio.
 *
 * Chunks are 80 ms, keeping the socket responsive without flooding it.
 */

const FALLBACK_SAMPLE_RATE = 16_000;

class SwaraPcmCapture extends AudioWorkletProcessor {
  constructor(options) {
    super(options);
    this.targetSampleRate =
      options.processorOptions?.targetSampleRate || FALLBACK_SAMPLE_RATE;
    this.chunkSamples = Math.round(this.targetSampleRate * 0.08);
    this.ratio = sampleRate / this.targetSampleRate;
    this.resampling = Math.abs(this.ratio - 1) > 0.01;
  }

  pending = new Float32Array(0);
  readPosition = 0;
  output = [];
  levelFrames = 0;
  squaredTotal = 0;

  emitLevel(samples) {
    for (let i = 0; i < samples.length; i += 1) {
      this.squaredTotal += samples[i] * samples[i];
    }
    this.levelFrames += samples.length;
    if (this.levelFrames >= sampleRate / 12) {
      const rms = Math.sqrt(this.squaredTotal / this.levelFrames);
      this.port.postMessage({ type: 'level', data: Math.min(1, rms * 3.2) });
      this.levelFrames = 0;
      this.squaredTotal = 0;
    }
  }

  flushChunks() {
    while (this.output.length >= this.chunkSamples) {
      const floats = this.output.splice(0, this.chunkSamples);
      const pcm = new Int16Array(this.chunkSamples);
      for (let i = 0; i < floats.length; i += 1) {
        const s = Math.max(-1, Math.min(1, floats[i]));
        pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
      }
      this.port.postMessage({ type: 'chunk', data: pcm.buffer }, [pcm.buffer]);
    }
  }

  process(inputs) {
    const samples = inputs[0]?.[0];
    if (!samples?.length) return true;

    this.emitLevel(samples);

    if (!this.resampling) {
      for (let i = 0; i < samples.length; i += 1) this.output.push(samples[i]);
      this.flushChunks();
      return true;
    }

    const merged = new Float32Array(this.pending.length + samples.length);
    merged.set(this.pending);
    merged.set(samples, this.pending.length);
    this.pending = merged;

    // Each output sample is the mean of the input window it covers, which
    // low-passes as it decimates instead of aliasing.
    while (this.readPosition + this.ratio < this.pending.length) {
      const start = Math.floor(this.readPosition);
      const end = Math.min(
        this.pending.length,
        Math.max(start + 1, Math.floor(this.readPosition + this.ratio)),
      );
      let sum = 0;
      for (let i = start; i < end; i += 1) sum += this.pending[i];
      this.output.push(sum / (end - start));
      this.readPosition += this.ratio;
    }

    const consumed = Math.floor(this.readPosition);
    if (consumed > 0) {
      this.pending = this.pending.slice(consumed);
      this.readPosition -= consumed;
    }

    this.flushChunks();
    return true;
  }
}

registerProcessor('swara-pcm-capture', SwaraPcmCapture);
