export class BitWriter {
  constructor(byteLength) {
    this.buffer = new Uint8Array(byteLength);
    this.bytePos = 0;
    this.bitPos = 0;
  }

  writeBit(bit) {
    if (bit !== 0 && bit !== 1) throw new Error("Bit must be 0 or 1");

    if (this.bytePos >= this.buffer.length) {
      throw new Error("Buffer overflow");
    }

    this.buffer[this.bytePos] |= (bit & 1) << (7 - this.bitPos);
    this.bitPos++;

    if (this.bitPos === 8) {
      this.bitPos = 0;
      this.bytePos++;
    }
  }

  writeBits(value, bitCount) {
    for (let i = bitCount - 1; i >= 0; i--) {
      const bit = (value >> i) & 1;
      this.writeBit(bit);
    }
  }

  getBuffer() {
    return this.buffer.buffer;
  }
}
