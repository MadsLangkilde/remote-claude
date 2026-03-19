// AudioWorklet processor: captures mic audio, downsamples to 16kHz, converts to PCM16
class PCM16Processor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this._targetRate = 16000;
    this._nativeRate = options.processorOptions?.sampleRate || sampleRate;
    this._resampleRatio = this._nativeRate / this._targetRate;
    this._resampleOffset = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || !input[0]) return true;

    const samples = input[0]; // mono channel

    // Downsample from native rate to 16kHz by picking every Nth sample
    const outLen = Math.floor((samples.length + this._resampleOffset) / this._resampleRatio);
    if (outLen <= 0) return true;

    const pcm16 = new Int16Array(outLen);
    let outIdx = 0;
    for (let i = 0; i < outLen; i++) {
      const srcIdx = Math.floor(i * this._resampleRatio - this._resampleOffset);
      if (srcIdx >= 0 && srcIdx < samples.length) {
        const s = Math.max(-1, Math.min(1, samples[srcIdx]));
        pcm16[outIdx++] = s < 0 ? s * 0x8000 : s * 0x7FFF;
      }
    }
    this._resampleOffset = (this._resampleOffset + samples.length) % this._resampleRatio;

    const result = pcm16.slice(0, outIdx);
    this.port.postMessage(result.buffer, [result.buffer]);
    return true;
  }
}

registerProcessor('pcm16-processor', PCM16Processor);
