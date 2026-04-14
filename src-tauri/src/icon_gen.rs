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

    for (size, filename) in sizes {
        let img = draw_icon(size);
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

    // --- Background: indigo diagonal gradient (4,4 to 60,60) ---
    for y in 0..size {
        for x in 0..size {
            let fx = x as f32 / size as f32;
            let fy = y as f32 / size as f32;
            let t = (fx + fy) / 2.0;
            let r = (0x4Fu8 as f32 + (0x81 - 0x4F) as f32 * t) as u8;
            let g = (0x46u8 as f32 + (0x8C - 0x46) as f32 * t) as u8;
            let b = (0xE5u8 as f32 + (0xF8 - 0xE5) as f32 * t) as u8;
            let idx = (y * size + x) * 4;
            pixels[idx..idx + 4].copy_from_slice(&[r, g, b, 255]);
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

    // --- White clipboard board ---
    fill_rect(&mut pixels, size, 17.0, 12.0, 47.0, 52.0, 255, 255, 255, 255);

    // --- Clip top (lighter indigo) ---
    fill_rect(&mut pixels, size, 23.0, 7.0, 41.0, 18.0, 0xE0, 0xE7, 0xFF, 255);

    // --- Clip hole ---
    fill_rect(&mut pixels, size, 27.0, 9.0, 37.0, 15.0, 0x4F, 0x46, 0xE5, 255);

    // --- Lines on clipboard ---
    for &ly in &[22.0, 28.0, 34.0, 40.0] {
        fill_rect(&mut pixels, size, 21.0, ly - 0.9, 43.0, ly + 0.9, 0xCB, 0xD5, 0xE1, 255);
    }

    // --- Orange dot with radial gradient ---
    fill_circle(
        &mut pixels, size,
        45.0, 47.0, 9.0,
        0xFB, 0x92, 0x3C,  // inner
        0xEA, 0x58, 0x0C,   // outer
    );

    // --- Clock circle (white stroke) ---
    let clock_cx = 45.0_f32;
    let clock_cy = 47.0_f32;
    let clock_r = 4.5_f32;
    let s = size as f32 / 64.0;
    let clock_ir = (clock_r * s).ceil() as i64;
    let thickness = (1.5_f32 * s).ceil() as i64;

    for dy in -clock_ir..=clock_ir {
        for dx in -clock_ir..=clock_ir {
            let d = ((dx * dx + dy * dy) as f64).sqrt();
            let inner = clock_ir - thickness;
            if d >= inner as f64 && d <= clock_ir as f64 {
                let px = clock_cx * s + dx as f32;
                let py = clock_cy * s + dy as f32;
                put_pixel(&mut pixels, size, px, py, 255, 255, 255, 255);
            }
        }
    }

    // --- Clock hands ---
    fill_rect(&mut pixels, size, 45.0 - 0.75, 44.0, 45.0 + 0.75, 47.0, 255, 255, 255, 255);
    fill_rect(&mut pixels, size, 45.0, 47.0 - 0.75, 47.5, 47.0 + 0.75, 255, 255, 255, 255);

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
