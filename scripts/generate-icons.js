import { createCanvas } from '@napi-rs/canvas';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import toIco from 'to-ico';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const iconsDir = path.resolve(__dirname, '..', 'src-tauri', 'icons');
fs.mkdirSync(iconsDir, { recursive: true });

// --- Draw icon at multiple sizes ---
function drawIcon(size) {
  const canvas = createCanvas(size, size);
  const ctx = canvas.getContext('2d');
  const s = size / 64;

  // Background gradient - indigo
  ctx.save();
  roundedRect(ctx, 4*s, 4*s, 56*s, 56*s, 10*s);
  const grad = ctx.createLinearGradient(4*s, 4*s, 60*s, 60*s);
  grad.addColorStop(0, '#4F46E5');
  grad.addColorStop(1, '#818CF8');
  ctx.fillStyle = grad;
  ctx.fill();
  ctx.restore();

  // White clipboard board
  ctx.save();
  roundedRect(ctx, 17*s, 12*s, 30*s, 40*s, 4*s);
  ctx.fillStyle = '#FFFFFF';
  ctx.fill();
  ctx.restore();

  // Clip top
  ctx.save();
  roundedRect(ctx, 23*s, 7*s, 18*s, 11*s, 3*s);
  ctx.fillStyle = '#E0E7FF';
  ctx.fill();
  ctx.restore();

  // Clip hole
  ctx.save();
  roundedRect(ctx, 27*s, 9*s, 10*s, 6*s, 2*s);
  ctx.fillStyle = '#4F46E5';
  ctx.fill();
  ctx.restore();

  // Lines
  ctx.save();
  ctx.strokeStyle = '#CBD5E1';
  ctx.lineWidth = 1.8*s;
  ctx.lineCap = 'round';
  [22, 28, 34, 40].forEach(y => {
    ctx.beginPath();
    ctx.moveTo(21*s, y*s);
    ctx.lineTo(43*s, y*s);
    ctx.stroke();
  });
  ctx.restore();

  // Orange dot
  ctx.save();
  ctx.beginPath();
  ctx.arc(45*s, 47*s, 9*s, 0, Math.PI * 2);
  const dotGrad = ctx.createRadialGradient(43*s, 45*s, 0, 45*s, 47*s, 9*s);
  dotGrad.addColorStop(0, '#FB923C');
  dotGrad.addColorStop(1, '#EA580C');
  ctx.fillStyle = dotGrad;
  ctx.fill();
  ctx.restore();

  // Clock hands
  ctx.save();
  ctx.strokeStyle = '#FFFFFF';
  ctx.lineWidth = 1.5*s;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.arc(45*s, 47*s, 4.5*s, 0, Math.PI * 2);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(45*s, 47*s);
  ctx.lineTo(45*s, 44*s);
  ctx.moveTo(45*s, 47*s);
  ctx.lineTo(47.5*s, 47*s);
  ctx.stroke();
  ctx.restore();

  return canvas;
}

function roundedRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + r);
  ctx.lineTo(x + w, y + h - r);
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  ctx.lineTo(x + r, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
}

// --- Generate PNGs for Tauri ---
const pngSizes = [
  [16, 'icon.png'],
  [32, '32x32.png'],
  [128, '128x128.png'],
  [256, '128x128@2x.png'],
];

for (const [size, filename] of pngSizes) {
  const canvas = drawIcon(size);
  fs.writeFileSync(path.join(iconsDir, filename), canvas.toBuffer('image/png'));
  console.log(`Generated ${filename}`);
}

// --- Generate real ICO with multiple sizes (16,32,48,256) ---
const icoSizes = [16, 32, 48, 256];
const pngBuffers = icoSizes.map(size => {
  const canvas = drawIcon(size);
  return canvas.toBuffer('image/png');
});

const icoBuffer = await toIco(pngBuffers);
fs.writeFileSync(path.join(iconsDir, 'icon.ico'), icoBuffer);
console.log(`Generated icon.ico (real ICO with ${icoSizes.join(',')}-pixel sizes)`);

// --- Generate ICNS (PNG works for dev/macOS builds) ---
const icns256 = drawIcon(256);
fs.writeFileSync(path.join(iconsDir, 'icon.icns'), icns256.toBuffer('image/png'));
console.log('Generated icon.icns (256x256 PNG)');

console.log(`\nAll icons → ${iconsDir}`);
