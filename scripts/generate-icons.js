import { createCanvas } from '@napi-rs/canvas';
import fs from 'fs';
import path from 'path';

import { fileURLToPath } from 'url';
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const iconsDir = path.join(__dirname, 'src-tauri', 'icons');
fs.mkdirSync(iconsDir, { recursive: true });

// Icon config: [size, filename]
const sizes = [
  [32, '32x32.png'],
  [128, '128x128.png'],
  [256, '128x128@2x.png'],
  [16, 'icon.png'],
];

// Generate a nice clipboard icon
function drawIcon(size) {
  const canvas = createCanvas(size, size);
  const ctx = canvas.getContext('2d');

  // Scale factor
  const s = size / 64;

  // Background: rounded square with gradient
  const bgColor = '#4F46E5'; // Indigo-600
  const lightColor = '#818CF8'; // Indigo-400
  const white = '#FFFFFF';

  // Draw background rounded rect
  ctx.save();
  roundedRect(ctx, 4*s, 4*s, 56*s, 56*s, 8*s);
  const grad = ctx.createLinearGradient(4*s, 4*s, 60*s, 60*s);
  grad.addColorStop(0, bgColor);
  grad.addColorStop(1, lightColor);
  ctx.fillStyle = grad;
  ctx.fill();
  ctx.restore();

  // Clipboard board (white)
  const boardX = 18*s, boardY = 10*s, boardW = 28*s, boardH = 40*s, boardR = 3*s;
  ctx.save();
  roundedRect(ctx, boardX, boardY, boardW, boardH, boardR);
  ctx.fillStyle = white;
  ctx.fill();
  ctx.restore();

  // Clipboard clip (top part)
  ctx.save();
  roundedRect(ctx, 24*s, 6*s, 16*s, 10*s, 3*s);
  ctx.fillStyle = white;
  ctx.fill();
  ctx.restore();

  // Inner clip hole
  ctx.save();
  roundedRect(ctx, 27*s, 8*s, 10*s, 5*s, 2*s);
  ctx.fillStyle = bgColor;
  ctx.fill();
  ctx.restore();

  // Lines on clipboard (text representation)
  ctx.save();
  ctx.strokeStyle = '#CBD5E1';
  ctx.lineWidth = 1.5*s;
  ctx.lineCap = 'round';
  [20, 26, 32, 38].forEach(y => {
    ctx.beginPath();
    ctx.moveTo(22*s, y*s);
    ctx.lineTo(42*s, y*s);
    ctx.stroke();
  });
  ctx.restore();

  // Clock/history indicator (small circle in bottom right)
  const cx = 44*s, cy = 46*s, cr = 8*s;
  ctx.save();
  ctx.beginPath();
  ctx.arc(cx, cy, cr, 0, Math.PI * 2);
  ctx.fillStyle = '#F97316'; // Orange-500
  ctx.fill();
  ctx.restore();

  // Clock hands
  ctx.save();
  ctx.strokeStyle = white;
  ctx.lineWidth = 1.5*s;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(cx, cy);
  ctx.lineTo(cx, cy - 4*s);
  ctx.moveTo(cx, cy);
  ctx.lineTo(cx + 3*s, cy + 1*s);
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

sizes.forEach(([size, filename]) => {
  const canvas = drawIcon(size);
  const buffer = canvas.toBuffer('image/png');
  fs.writeFileSync(path.join(iconsDir, filename), buffer);
  console.log(`Generated ${filename} (${size}x${size})`);
});

// Also generate icon.ico (Windows) — we create a 256x256 PNG and rename
// Real .ico needs multiple sizes; for Tauri, 256x256 PNG works as icon.ico
const ico256 = drawIcon(256);
const icoBuffer = ico256.toBuffer('image/png');
fs.writeFileSync(path.join(iconsDir, 'icon.ico'), icoBuffer);
console.log('Generated icon.ico (256x256 PNG)');

// Also generate icon.icns (macOS) — PNG is fine for dev, real icns needs conversion
fs.writeFileSync(path.join(iconsDir, 'icon.icns'), icoBuffer);
console.log('Generated icon.icns (256x256 PNG)');

console.log('\nAll icons generated successfully!');
