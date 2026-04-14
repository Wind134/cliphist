import { createCanvas } from '@napi-rs/canvas';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// Target: src-tauri/icons/
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const iconsDir = path.resolve(__dirname, '..', 'src-tauri', 'icons');
fs.mkdirSync(iconsDir, { recursive: true });

// Sizes needed for Tauri
const sizes = [
  [16, 'icon.png'],
  [32, '32x32.png'],
  [128, '128x128.png'],
  [256, '128x128@2x.png'],
];

function drawIcon(size) {
  const canvas = createCanvas(size, size);
  const ctx = canvas.getContext('2d');
  const s = size / 64;

  // Background gradient - indigo
  const bgColor = '#4F46E5';
  const lightColor = '#818CF8';

  ctx.save();
  roundedRect(ctx, 4*s, 4*s, 56*s, 56*s, 10*s);
  const grad = ctx.createLinearGradient(4*s, 4*s, 60*s, 60*s);
  grad.addColorStop(0, bgColor);
  grad.addColorStop(1, lightColor);
  ctx.fillStyle = grad;
  ctx.fill();
  ctx.restore();

  // Clipboard board (white) with shadow effect
  ctx.save();
  roundedRect(ctx, 17*s, 12*s, 30*s, 40*s, 4*s);
  ctx.fillStyle = '#FFFFFF';
  ctx.fill();
  // subtle inner shadow
  ctx.strokeStyle = 'rgba(0,0,0,0.1)';
  ctx.lineWidth = 1*s;
  ctx.stroke();
  ctx.restore();

  // Clipboard clip top
  ctx.save();
  roundedRect(ctx, 23*s, 7*s, 18*s, 11*s, 3*s);
  ctx.fillStyle = '#E0E7FF';
  ctx.fill();
  ctx.restore();

  // Clip hole (dark)
  ctx.save();
  roundedRect(ctx, 27*s, 9*s, 10*s, 6*s, 2*s);
  ctx.fillStyle = bgColor;
  ctx.fill();
  ctx.restore();

  // Lines on clipboard
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

  // Orange dot (history indicator, bottom right)
  ctx.save();
  ctx.beginPath();
  ctx.arc(45*s, 47*s, 9*s, 0, Math.PI * 2);
  const dotGrad = ctx.createRadialGradient(43*s, 45*s, 0, 45*s, 47*s, 9*s);
  dotGrad.addColorStop(0, '#FB923C');
  dotGrad.addColorStop(1, '#EA580C');
  ctx.fillStyle = dotGrad;
  ctx.fill();
  ctx.restore();

  // Clock face on dot
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

// Generate all PNG sizes
for (const [size, filename] of sizes) {
  const canvas = drawIcon(size);
  const buffer = canvas.toBuffer('image/png');
  fs.writeFileSync(path.join(iconsDir, filename), buffer);
  console.log(`Generated ${filename} (${size}x${size})`);
}

// For Windows ICO: create a 256x256 PNG (Tauri NSIS accepts PNG as icon)
const ico256 = drawIcon(256);
const icoBuffer = ico256.toBuffer('image/png');
fs.writeFileSync(path.join(iconsDir, 'icon.ico'), icoBuffer);
console.log('Generated icon.ico (256x256 PNG - Tauri NSIS compatible)');

// For macOS ICNS: PNG works for dev builds
fs.writeFileSync(path.join(iconsDir, 'icon.icns'), icoBuffer);
console.log('Generated icon.icns (256x256 PNG - macOS compatible)');

console.log(`\nAll icons written to: ${iconsDir}`);
console.log('Done!');
