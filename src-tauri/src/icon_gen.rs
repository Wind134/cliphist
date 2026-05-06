//! Icon generator for ClipHist.
//! Replaces the Node.js generate-icons.js script.
//! Generates all required icon files from pure pixel drawing.
use std::fs::File;
use std::io::{BufWriter, Cursor, Seek, Write};
use std::path::PathBuf;

fn main() {
    let icons_dir = PathBuf::from("icons");
    std::fs::create_dir_all(&icons_dir).unwrap();

    let sizes: [(usize, &str); 5] = [
        (16, "icon.png"),
        (32, "32x32.png"),
        (48, "48x48.png"),
        (128, "128x128.png"),
        (256, "128x128@2x.png"),
    ];

    for (size, filename) in &sizes {
        let img = draw_icon(*size);
        let path = icons_dir.join(filename);
        img.save(&path).unwrap();
        println!("Generated {}", path.display());
    }

    // Windows Store logos
    let store_sizes: [(usize, &str); 10] = [
        (30, "Square30x30Logo.png"),
        (44, "Square44x44Logo.png"),
        (50, "StoreLogo.png"),
        (71, "Square71x71Logo.png"),
        (89, "Square89x89Logo.png"),
        (107, "Square107x107Logo.png"),
        (142, "Square142x142Logo.png"),
        (150, "Square150x150Logo.png"),
        (284, "Square284x284Logo.png"),
        (310, "Square310x310Logo.png"),
    ];

    for (size, filename) in &store_sizes {
        let img = draw_icon(*size);
        let path = icons_dir.join(filename);
        img.save(&path).unwrap();
        println!("Generated {}", path.display());
    }

    // Generate icon.ico: ICO header + entry per image + PNG data blobs
    let ico_sizes = [16, 32, 48, 256];
    let png_buffers: Vec<Vec<u8>> = ico_sizes
        .iter()
        .map(|&s| {
            let img = draw_icon(s);
            let mut buf = Vec::new();
            img.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png)
                .unwrap();
            buf
        })
        .collect();

    let ico_path = icons_dir.join("icon.ico");
    write_ico(&ico_path, &png_buffers, &ico_sizes).unwrap();
    println!("Generated {}", ico_path.display());

    // For macOS: icon.icns must be a real ICNS, but the macOS build
    // process will extract from the PNG. We just put a PNG here as placeholder.
    let img256 = draw_icon(256);
    img256
        .save_with_format(icons_dir.join("icon.icns"), image::ImageFormat::Png)
        .unwrap();
    println!("Generated {}/icon.icns (PNG placeholder)", icons_dir.display());

    println!("\nAll icons generated in {}", icons_dir.display());
}

/// Draw the clipboard icon at `size` pixels.
fn draw_icon(size: usize) -> image::RgbaImage {
    let mut pixels: Vec<u8> = vec![0; size * size * 4];

    // --- Background: modern blue-purple gradient with rounded corners ---
    for y in 0..size {
        for x in 0..size {
            let fx = x as f32 / size as f32;
            let fy = y as f32 / size as f32;
            let t = (fx * 0.6 + fy * 0.4).min(1.0);
            // Deep blue to vibrant purple gradient
            let r = (0x30u8 as f32 + (0x7E - 0x30) as f32 * t) as u8;
            let g = (0x50u8 as f32 + (0x28 - 0x50) as f32 * t) as u8;
            let b = (0xF0u8 as f32 + (0xE8 - 0xF0) as f32 * t) as u8;
            let idx = (y * size + x) * 4;

            // Rounded corner mask
            let margin = size as f32 * 0.06;
            let corner_r = size as f32 * 0.18;
            let xf = x as f32;
            let yf = y as f32;
            let w = size as f32;
            let in_corner = |cx: f32, cy: f32| {
                let dx = xf - cx;
                let dy = yf - cy;
                (dx * dx + dy * dy).sqrt() <= corner_r
            };
            let alpha = if xf < margin + corner_r && yf < margin + corner_r {
                if in_corner(margin + corner_r, margin + corner_r) { 1.0 } else { 0.0 }
            } else if xf > w - margin - corner_r && yf < margin + corner_r {
                if in_corner(w - margin - corner_r, margin + corner_r) { 1.0 } else { 0.0 }
            } else if xf < margin + corner_r && yf > w - margin - corner_r {
                if in_corner(margin + corner_r, w - margin - corner_r) { 1.0 } else { 0.0 }
            } else if xf > w - margin - corner_r && yf > w - margin - corner_r {
                if in_corner(w - margin - corner_r, w - margin - corner_r) { 1.0 } else { 0.0 }
            } else {
                1.0
            };

            pixels[idx] = r;
            pixels[idx + 1] = g;
            pixels[idx + 2] = b;
            pixels[idx + 3] = (alpha * 255.0) as u8;
        }
    }

    // Helper: write a single pixel (with simple over blending)
    fn put_pixel(pixels: &mut [u8], size: usize, fx: f32, fy: f32, r: u8, g: u8, b: u8, a: u8) {
        let s = size as f32 / 64.0;
        let px = (fx * s) as i64;
        let py = (fy * s) as i64;
        if px < 0 || py < 0 || px >= size as i64 || py >= size as i64 {
            return;
        }
        let idx = ((py as usize) * size + (px as usize)) * 4;
        let alpha = a as f32 / 255.0;
        let inv = 1.0 - alpha;
        pixels[idx] = (r as f32 * alpha + pixels[idx] as f32 * inv) as u8;
        pixels[idx + 1] = (g as f32 * alpha + pixels[idx + 1] as f32 * inv) as u8;
        pixels[idx + 2] = (b as f32 * alpha + pixels[idx + 2] as f32 * inv) as u8;
        pixels[idx + 3] = 255;
    }

    // Helper: fill axis-aligned rectangle
    fn fill_rect(
        pixels: &mut [u8], size: usize,
        x0: f32, y0: f32, x1: f32, y1: f32,
        r: u8, g: u8, b: u8, a: u8,
    ) {
        let s = size as f32 / 64.0;
        let sx0 = (x0 * s).ceil() as i64;
        let sy0 = (y0 * s).ceil() as i64;
        let ex0 = (x1 * s).floor() as i64;
        let ey0 = (y1 * s).floor() as i64;
        for py in sy0..=ey0 {
            for px in sx0..=ex0 {
                if px >= 0 && py >= 0 && px < size as i64 && py < size as i64 {
                    let idx = ((py as usize) * size + (px as usize)) * 4;
                    let alpha = a as f32 / 255.0;
                    let inv = 1.0 - alpha;
                    pixels[idx] = (r as f32 * alpha + pixels[idx] as f32 * inv) as u8;
                    pixels[idx + 1] = (g as f32 * alpha + pixels[idx + 1] as f32 * inv) as u8;
                    pixels[idx + 2] = (b as f32 * alpha + pixels[idx + 2] as f32 * inv) as u8;
                    pixels[idx + 3] = 255;
                }
            }
        }
    }

    // Helper: fill circle with radial gradient
    fn fill_circle(
        pixels: &mut [u8], size: usize,
        cx: f32, cy: f32, radius: f32,
        r_inner: u8, g_inner: u8, b_inner: u8,
        r_outer: u8, g_outer: u8, b_outer: u8,
    ) {
        let s = size as f32 / 64.0;
        let cxc = cx * s;
        let cyc = cy * s;
        let cr = radius * s;
        let ir = cr.ceil() as i64;

        for dy in -ir..=ir {
            for dx in -ir..=ir {
                let d = ((dx * dx + dy * dy) as f64).sqrt();
                if d <= cr as f64 {
                    let frac = (d / cr as f64).min(1.0) as f32;
                    let r = (r_inner as f32 + (r_outer as f32 - r_inner as f32) * frac) as u8;
                    let g = (g_inner as f32 + (g_outer as f32 - g_inner as f32) * frac) as u8;
                    let b = (b_inner as f32 + (b_outer as f32 - b_inner as f32) * frac) as u8;
                    let px = cxc + dx as f32;
                    let py = cyc + dy as f32;
                    put_pixel(pixels, size, px, py, r, g, b, 255);
                }
            }
        }
    }

    // --- White clipboard board (with subtle shadow) ---
    fill_rect(&mut pixels, size, 16.0, 13.0, 48.0, 53.0, 245, 245, 250, 255);
    fill_rect(&mut pixels, size, 17.0, 12.0, 47.0, 52.0, 255, 255, 255, 255);

    // --- Clip top (gradient purple) ---
    fill_rect(&mut pixels, size, 22.0, 7.0, 42.0, 18.0, 0xC7, 0xD2, 0xFE, 255);

    // --- Clip hole (deep purple) ---
    fill_rect(&mut pixels, size, 27.0, 9.0, 37.0, 15.0, 0x5B, 0x21, 0xB6, 255);

    // --- Lines on clipboard (subtle gray) ---
    for &ly in &[23.0, 29.0, 35.0, 41.0] {
        fill_rect(&mut pixels, size, 21.0, ly - 0.8, 43.0, ly + 0.8, 0xE2, 0xE8, 0xF0, 255);
    }

    // --- Vibrant teal dot with radial gradient ---
    fill_circle(
        &mut pixels, size,
        46.0, 47.0, 9.5,
        0x2D, 0xD4, 0xBF,  // inner (bright teal)
        0x0D, 0x94, 0x88,  // outer (deep teal)
    );

    // --- Clock circle (white stroke, slightly thicker) ---
    let clock_cx = 46.0_f32;
    let clock_cy = 47.0_f32;
    let clock_r = 5.0_f32;
    let s = size as f32 / 64.0;
    let clock_ir = (clock_r * s).ceil() as i64;
    let thickness = (1.8_f32 * s).ceil() as i64;

    for dy in -clock_ir..=clock_ir {
        for dx in -clock_ir..=clock_ir {
            let d = ((dx * dx + dy * dy) as f64).sqrt();
            let inner = clock_ir - thickness;
            if d >= inner as f64 && d <= clock_ir as f64 {
                let px = clock_cx * s + dx as f32;
                let py = clock_cy * s + dy as f32;
                put_pixel(&mut pixels, size, px, py, 255, 255, 255, 240);
            }
        }
    }

    // --- Clock hands (thicker, cleaner) ---
    fill_rect(&mut pixels, size, 46.0 - 0.8, 43.5, 46.0 + 0.8, 47.0, 255, 255, 255, 255);
    fill_rect(&mut pixels, size, 46.0, 47.0 - 0.8, 49.0, 47.0 + 0.8, 255, 255, 255, 255);

    image::RgbaImage::from_raw(size as u32, size as u32, pixels)
        .expect("failed to create RgbaImage")
}

/// Write a modern ICO file embedding PNG data.
/// Format: ICONDIR header + N × ICONDIRENTRY + N × PNG blob
fn write_ico(path: &PathBuf, png_buffers: &[Vec<u8>], sizes: &[usize]) -> std::io::Result<()> {
    use byteorder::{LittleEndian, WriteBytesExt};

    let num_images = png_buffers.len() as u16;

    // Header: 6 bytes
    let header_size = 6;
    // Each entry: 16 bytes
    let entry_size = 16 * num_images as usize;
    // Data starts after header + entries
    let first_offset = header_size + entry_size;

    let mut file = BufWriter::new(File::create(path)?);

    // --- ICONDIR ---
    file.write_u16::<LittleEndian>(0)?;        // Reserved (must be 0)
    file.write_u16::<LittleEndian>(1)?;        // Type: 1 = ICO
    file.write_u16::<LittleEndian>(num_images)?; // Number of images

    // --- ICONDIRENTRY for each image ---
    // Collect offsets to fill in later
    let mut offsets: Vec<u32> = Vec::with_capacity(num_images as usize);
    let mut current_offset = first_offset as u32;

    for (&size, png) in sizes.iter().zip(png_buffers.iter()) {
        let w = if size == 256 { 0u8 } else { size as u8 };
        let h = if size == 256 { 0u8 } else { size as u8 };

        file.write_u8(w)?;                         // Width
        file.write_u8(h)?;                         // Height
        file.write_u8(0)?;                         // Color palette (0 = no palette)
        file.write_u8(0)?;                         // Reserved
        file.write_u16::<LittleEndian>(1)?;       // Color planes
        file.write_u16::<LittleEndian>(32)?;      // Bits per pixel
        file.write_u32::<LittleEndian>(png.len() as u32)?; // Image data size
        file.write_u32::<LittleEndian>(current_offset)?;  // Offset to image data

        offsets.push(current_offset);
        current_offset += png.len() as u32;
    }

    // --- PNG data blobs ---
    for (png, &offset) in png_buffers.iter().zip(offsets.iter()) {
        let pos = file.stream_position()?;
        assert_eq!(pos as u32, offset);
        file.write_all(png)?;
    }

    Ok(())
}
