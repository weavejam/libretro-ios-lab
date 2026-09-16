#!/usr/bin/env node
// Generates the NES test ROM used by the smoke tests.
//
// We author this ROM ourselves (public domain, see LICENSE) rather than shipping a
// commercial ROM. It is a minimal NROM-128 image whose only job is to make the core's
// output *unambiguously checkable* from a unit test:
//
//   * it sets the universal backdrop colour ($3F00) to a bright blue and enables
//     background rendering, so every one of the 256x240 pixels is that exact colour —
//     including when the emulator powers up VRAM with garbage, because colour index 0
//     of every palette mirrors the backdrop. A blank/black frame therefore means the
//     core did not actually run.
//   * it starts a constant-volume square wave on APU pulse 1 with the length counter
//     halted, so audio keeps flowing forever and a silent buffer is a real failure.
//
// Usage: node tools/make-test-rom.mjs [--out path]

import fs from 'node:fs';
import path from 'node:path';

const PRG_BANKS = 1; // 16 KiB
const CHR_BANKS = 1; // 8 KiB
const PRG_SIZE = PRG_BANKS * 16384;
const CHR_SIZE = CHR_BANKS * 8192;
const ORG = 0xc000; // NROM-128 maps the single PRG bank at $C000 (mirrored at $8000)

const prg = Buffer.alloc(PRG_SIZE, 0x00);
let pc = 0;
const emit = (...bytes) => {
  for (const b of bytes) prg[pc++] = b & 0xff;
};
const addr = () => ORG + pc;
// Backward relative branch to a previously recorded address. Called while `pc` still points
// at the branch opcode, and 6502 relative offsets are measured from the *next* instruction,
// hence +2 (opcode + operand).
const rel = (target) => {
  const delta = target - (addr() + 2);
  if (delta < -128 || delta > 127) throw new Error(`branch out of range: ${delta}`);
  return delta & 0xff;
};

emit(0x78); //            SEI
emit(0xd8); //            CLD
emit(0xa2, 0x40); //      LDX #$40
emit(0x8e, 0x17, 0x40); // STX $4017      ; silence the APU frame IRQ
emit(0xa2, 0xff); //      LDX #$FF
emit(0x9a); //            TXS
emit(0xe8); //            INX            ; X = 0
emit(0x8e, 0x00, 0x20); // STX $2000      ; PPUCTRL = 0 (NMI off)
emit(0x8e, 0x01, 0x20); // STX $2001      ; PPUMASK = 0 (rendering off)
emit(0x8e, 0x10, 0x40); // STX $4010      ; DMC IRQ off

// The PPU is not ready until two vblanks have passed after reset.
const vb1 = addr();
emit(0x2c, 0x02, 0x20); // BIT $2002
emit(0x10, rel(vb1)); //  BPL vb1
const vb2 = addr();
emit(0x2c, 0x02, 0x20); // BIT $2002
emit(0x10, rel(vb2)); //  BPL vb2

// Palette write: $3F00 (universal backdrop) = $21, a light blue.
emit(0xa9, 0x3f); //      LDA #$3F
emit(0x8d, 0x06, 0x20); // STA $2006
emit(0xa9, 0x00); //      LDA #$00
emit(0x8d, 0x06, 0x20); // STA $2006
emit(0xa9, 0x21); //      LDA #$21
emit(0x8d, 0x07, 0x20); // STA $2007

// Reset the PPU address/scroll latches so rendering starts at (0,0).
emit(0xa9, 0x00); //      LDA #$00
emit(0x8d, 0x06, 0x20); // STA $2006
emit(0x8d, 0x06, 0x20); // STA $2006
emit(0x8d, 0x05, 0x20); // STA $2005
emit(0x8d, 0x05, 0x20); // STA $2005

// APU pulse 1: duty 2, length-counter halted, constant volume 15, ~654 Hz.
emit(0xa9, 0x01); //      LDA #$01
emit(0x8d, 0x15, 0x40); // STA $4015      ; enable pulse 1
emit(0xa9, 0xbf); //      LDA #$BF
emit(0x8d, 0x00, 0x40); // STA $4000      ; duty/halt/constant volume
emit(0xa9, 0x08); //      LDA #$08
emit(0x8d, 0x01, 0x40); // STA $4001      ; sweep disabled
emit(0xa9, 0xaa); //      LDA #$AA
emit(0x8d, 0x02, 0x40); // STA $4002      ; timer low
emit(0xa9, 0x00); //      LDA #$00
emit(0x8d, 0x03, 0x40); // STA $4003      ; timer high + length load (starts the tone)

// Enable background rendering (leftmost column included).
emit(0xa9, 0x0a); //      LDA #$0A
emit(0x8d, 0x01, 0x20); // STA $2001

const loop = addr();
emit(0x4c, loop & 0xff, (loop >> 8) & 0xff); // JMP loop

const RESET = ORG;
const HANDLER = loop; // NMI/IRQ are disabled; point them somewhere harmless anyway.
const vec = (a) => [a & 0xff, (a >> 8) & 0xff];
prg.set(vec(HANDLER), 0x3ffa); // NMI
prg.set(vec(RESET), 0x3ffc); // RESET
prg.set(vec(HANDLER), 0x3ffe); // IRQ

// All-zero CHR: every tile is colour index 0, i.e. the backdrop, whatever VRAM holds.
const chr = Buffer.alloc(CHR_SIZE, 0x00);

const header = Buffer.alloc(16, 0x00);
header.write('NES\x1a', 'binary');
header[4] = PRG_BANKS;
header[5] = CHR_BANKS;
header[6] = 0x00; // mapper 0, horizontal mirroring
header[7] = 0x00;

const rom = Buffer.concat([header, prg, chr]);

const outIdx = process.argv.indexOf('--out');
const out =
  outIdx >= 0 && process.argv[outIdx + 1]
    ? process.argv[outIdx + 1]
    : path.join('Tests', 'LibretroKitTests', 'Resources', 'testrom.nes');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, rom);
console.log(`wrote ${out} (${rom.length} bytes, ${pc} bytes of code)`);
