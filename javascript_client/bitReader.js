export class BitReader {
  constructor(buffer) {
    if (buffer instanceof ArrayBuffer) {
      this.buffer = new Uint8Array(buffer);
    } else if (buffer instanceof Uint8Array) {
      this.buffer = buffer;
    } else {
      throw new Error("Buffer must be an ArrayBuffer or Uint8Array");
    }
    this.bytePos = 0;
    this.bitPos = 0;
  }

  readBit() {
    if (this.bytePos >= this.buffer.length) {
      throw new Error("Buffer overflow");
    }

    // Read the bit at current position: bits stored from MSB to LSB
    const bit = (this.buffer[this.bytePos] >> (7 - this.bitPos)) & 1;

    this.bitPos++;
    if (this.bitPos === 8) {
      this.bitPos = 0;
      this.bytePos++;
    }

    return bit;
  }

  readBits(bitCount) {
    let value = 0;
    for (let i = 0; i < bitCount; i++) {
      value = (value << 1) | this.readBit();
    }
    return value;
  }

  getReadBits() {
    return this.bytePos * 8 + this.bitPos;
  }

  getRemainingBits() {
    return this.buffer.length * 8 - this.getReadBits();
  }

  readRemainingBits() {
    const remaining = this.getRemainingBits()
    const remainingBytes = remaining / 8
    const output = new Uint8Array(remainingBytes)
    for (let i = 0; i < remainingBytes; i++) {
      const bits = this.readBits(8)
      output.set([bits], i)
    }
    return output
  }
}

