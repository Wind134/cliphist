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

/// Draw the clipboard icon at `size` pixels with 2x supersampling for antialiasing.
fn draw_icon(size: usize) -> image::RgbaImage {
    // Use 2x supersampling for better antialiasing
    let ss = 2;
    let draw_size = size * ss;
    let mut pixels: Vec<u8> = vec![0; draw_size * draw_size * 4];
    let s = draw_size as f32 / 64.0;

    // Helper: write a single pixel with alpha blending
    fn put_pixel(pixels: &mut [u8], draw_size: usize, px: i64, py: i64, r: u8, g: u8, b: u8, a: f32) {
        if px < 0 || py < 0 || px >= draw_size as i64 || py >= draw_size as i64 {
            return;
        }
        let idx = ((py as usize) * draw_size + (px as usize)) * 4;
        let inv = 1.0 - a;
        pixels[idx] = (r as f32 * a + pixels[idx] as f32 * inv) as u8;
        pixels[idx + 1] = (g as f32 * a + pixels[idx + 1] as f32 * inv) as u8;
        pixels[idx + 2] = (b as f32 * a + pixels[idx + 2] as f32 * inv) as u8;
        pixels[idx + 3] = 255;
    }

    // Helper: fill rounded rectangle with antialiased edges
    fn fill_rounded_rect(
        pixels: &mut [u8], draw_size: usize, s: f32,
        x0: f32, y0: f32, x1: f32, y1: f32, radius: f32,
        r: u8, g: u8, b: u8, a: u8,
    ) {
        let sx0 = (x0 * s).floor() as i64;
        let sy0 = (y0 * s).floor() as i64;
        let ex0 = (x1 * s).ceil() as i64;
        let ey0 = (y1 * s).ceil() as i64;
        let r_scaled = radius * s;
        let alpha = a as f32 / 255.0;

        for py in sy0..=ey0 {
            for px in sx0..=ex0 {
                // Distance to rectangle edge (with rounded corners)
                let fx = px as f32;
                let fy = py as f32;
                let left = x0 * s;
                let right = x1 * s;
                let top = y0 * s;
                let bottom = y1 * s;

                // Distance from each edge
                let dl = left - fx;
                let dr = fx - right;
                let dt = top - fy;
                let db = fy - bottom;

                // Distance to corner circles
                let dx = dl.max(0.0).max(dr.max(0.0));
                let dy = dt.max(0.0).max(db.max(0.0));
                let dist = (dx * dx + dy * dy).sqrt() - r_scaled;

                // Antialiasing: smooth transition at edge
                let aa = if dist <= -1.5 {
                    1.0
                } else if dist >= 1.5 {
                    0.0
                } else {
                    0.5 - dist * 0.33
                };

                if aa > 0.0 {
                    put_pixel(pixels, draw_size, px, py, r, g, b, alpha * aa);
                }
            }
        }
    }

    // Helper: fill rectangle (no rounded corners)
    fn fill_rect(
        pixels: &mut [u8], draw_size: usize, s: f32,
        x0: f32, y0: f32, x1: f32, y1: f32,
        r: u8, g: u8, b: u8, a: u8,
    ) {
        fill_rounded_rect(pixels, draw_size, s, x0, y0, x1, y1, 0.0, r, g, b, a);
    }

    // Helper: fill circle with radial gradient and antialiasing
    fn fill_circle(
        pixels: &mut [u8], draw_size: usize, s: f32,
        cx: f32, cy: f32, radius: f32,
        r_inner: u8, g_inner: u8, b_inner: u8,
        r_outer: u8, g_outer: u8, b_outer: u8,
    ) {
        let cxc = cx * s;
        let cyc = cy * s;
        let cr = radius * s;
        let ir = (cr + 1.5).ceil() as i64;

        for dy in -ir..=ir {
            for dx in -ir..=ir {
                let d = ((dx * dx + dy * dy) as f32).sqrt();
                let dist = d - cr;

                // Antialiasing
                let aa = if dist <= -1.5 {
                    1.0
                } else if dist >= 1.5 {
                    0.0
                } else {
                    0.5 - dist * 0.33
                };

                if aa > 0.0 {
                    let frac = (d / cr).min(1.0);
                    let r = (r_inner as f32 + (r_outer as f32 - r_inner as f32) * frac) as u8;
                    let g = (g_inner as f32 + (g_outer as f32 - g_inner as f32) * frac) as u8;
                    let b = (b_inner as f32 + (b_outer as f32 - b_inner as f32) * frac) as u8;
                    let px = cxc + dx as f32;
                    let py = cyc + dy as f32;
                    put_pixel(pixels, draw_size, px as i64, py as i64, r, g, b, aa);
                }
            }
        }
    }

    // Helper: draw antialiased line
    fn fill_line(
        pixels: &mut [u8], draw_size: usize, s: f32,
        x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32,
        r: u8, g: u8, b: u8, a: u8,
    ) {
        let sx0 = x0 * s;
        let sy0 = y0 * s;
        let sx1 = x1 * s;
        let sy1 = y1 * s;
        let t = thickness * s;
        let half_t = t / 2.0;

        // Bounding box
        let min_x = (sx0.min(sx1) - half_t - 1.0).floor() as i64;
        let max_x = (sx0.max(sx1) + half_t + 1.0).ceil() as i64;
        let min_y = (sy0.min(sy1) - half_t - 1.0).floor() as i64;
        let max_y = (sy0.max(sy1) + half_t + 1.0).ceil() as i64;

        let dx = sx1 - sx0;
        let dy = sy1 - sy0;
        let len_sq = dx * dx + dy * dy;
        let alpha = a as f32 / 255.0;

        for py in min_y..=max_y {
            for px in min_x..=max_x {
                let fx = px as f32 + 0.5;
                let fy = py as f32 + 0.5;

                // Distance from point to line segment
                let t_param = if len_sq > 0.0 {
                    ((fx - sx0) * dx + (fy - sy0) * dy / len_sq).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                let proj_x = sx0 + t_param * dx;
                let proj_y = sy0 + t_param * dy;
                let dist = ((fx - proj_x).powi(2) + (fy - proj_y).powi(2)).sqrt() - half_t;

                let aa = if dist <= -1.5 {
                    1.0
                } else if dist >= 1.5 {
                    0.0
                } else {
                    0.5 - dist * 0.33
                };

                if aa > 0.0 {
                    put_pixel(pixels, draw_size, px, py, r, g, b, alpha * aa);
                }
            }
        }
    }

    // --- Background: modern blue-purple gradient with rounded corners ---
    for y in 0..draw_size {
        for x in 0..draw_size {
            let fx = x as f32 / draw_size as f32;
            let fy = y as f32 / draw_size as f32;
            let t = (fx * 0.6 + fy * 0.4).min(1.0);
            let r = (0x30u8 as f32 + (0x7E - 0x30) as f32 * t) as u8;
            let g = (0x50u8 as f32 + (0x28 - 0x50) as f32 * t) as u8;
            let b = (0xF0u8 as f32 + (0xE8 - 0xF0) as f32 * t) as u8;

            // Rounded corner with antialiasing
            let margin = if draw_size <= 64 { 0.0 } else { draw_size as f32 * 0.06 };
            let corner_r = if draw_size <= 64 { 0.0 } else { draw_size as f32 * 0.15 };
            let xf = x as f32;
            let yf = y as f32;
            let w = draw_size as f32;

            let dist = if xf < margin + corner_r && yf < margin + corner_r {
                let dx = xf - (margin + corner_r);
                let dy = yf - (margin + corner_r);
                (dx * dx + dy * dy).sqrt() - corner_r
            } else if xf > w - margin - corner_r && yf < margin + corner_r {
                let dx = xf - (w - margin - corner_r);
                let dy = yf - (margin + corner_r);
                (dx * dx + dy * dy).sqrt() - corner_r
            } else if xf < margin + corner_r && yf > w - margin - corner_r {
                let dx = xf - (margin + corner_r);
                let dy = yf - (w - margin - corner_r);
                (dx * dx + dy * dy).sqrt() - corner_r
            } else if xf > w - margin - corner_r && yf > w - margin - corner_r {
                let dx = xf - (w - margin - corner_r);
                let dy = yf - (w - margin - corner_r);
                (dx * dx + dy * dy).sqrt() - corner_r
            } else {
                -1.0 // Inside
            };

            let alpha = if dist <= -1.5 {
                1.0
            } else if dist >= 1.5 {
                0.0
            } else {
                0.5 - dist * 0.33
            };

            let idx = (y * draw_size + x) * 4;
            pixels[idx] = r;
            pixels[idx + 1] = g;
            pixels[idx + 2] = b;
            pixels[idx + 3] = (alpha * 255.0) as u8;
        }
    }

    // --- White clipboard board (with subtle shadow) ---
    fill_rounded_rect(&mut pixels, draw_size, s, 16.0, 13.0, 48.0, 53.0, 2.0, 245, 245, 250, 255);
    fill_rounded_rect(&mut pixels, draw_size, s, 17.0, 12.0, 47.0, 52.0, 2.0, 255, 255, 255, 255);

    // --- Clip top (gradient purple) ---
    fill_rounded_rect(&mut pixels, draw_size, s, 22.0, 7.0, 42.0, 18.0, 2.0, 0xC7, 0xD2, 0xFE, 255);

    // --- Clip hole (deep purple) ---
    fill_rounded_rect(&mut pixels, draw_size, s, 27.0, 9.0, 37.0, 15.0, 1.0, 0x5B, 0x21, 0xB6, 255);

    // --- Lines on clipboard (subtle gray) ---
    for &ly in &[23.0, 29.0, 35.0, 41.0] {
        fill_rect(&mut pixels, draw_size, s, 21.0, ly - 0.8, 43.0, ly + 0.8, 0xE2, 0xE8, 0xF0, 255);
    }

    // --- Vibrant teal dot with radial gradient ---
    fill_circle(
        &mut pixels, draw_size, s,
        46.0, 47.0, 9.5,
        0x2D, 0xD4, 0xBF,
        0x0D, 0x94, 0x88,
    );

    // --- Clock circle (white stroke, antialiased) ---
    let clock_cx = 46.0_f32;
    let clock_cy = 47.0_f32;
    let clock_r = 5.0_f32;
    let clock_ir = (clock_r * s).ceil() as i64;
    let thickness = 1.8 * s;

    for dy in -clock_ir..=clock_ir {
        for dx in -clock_ir..=clock_ir {
            let d = ((dx * dx + dy * dy) as f32).sqrt();
            let dist_outer = d - clock_r * s;
            let dist_inner = d - (clock_r * s - thickness);

            // Ring: outside inner circle, inside outer circle
            if dist_outer <= 1.5 && dist_inner >= -1.5 {
                let aa_outer = if dist_outer <= -1.5 { 1.0 }
                    else if dist_outer >= 1.5 { 0.0 }
                    else { 0.5 - dist_outer * 0.33 };
                let aa_inner = if dist_inner <= -1.5 { 0.0 }
                    else if dist_inner >= 1.5 { 1.0 }
                    else { 0.5 + dist_inner * 0.33 };
                let aa = aa_outer * aa_inner;

                if aa > 0.0 {
                    let px = clock_cx * s + dx as f32;
                    let py = clock_cy * s + dy as f32;
                    put_pixel(&mut pixels, draw_size, px as i64, py as i64, 255, 255, 255, aa * 0.94);
                }
            }
        }
    }

    // --- Clock hands (antialiased lines) ---
    fill_line(&mut pixels, draw_size, s, 46.0, 43.5, 46.0, 47.0, 1.6, 255, 255, 255, 255);
    fill_line(&mut pixels, draw_size, s, 46.0, 47.0, 49.0, 47.0, 1.6, 255, 255, 255, 255);

    // Downsample from draw_size to size using simple averaging
    let mut result: Vec<u8> = vec![0; size * size * 4];
    for y in 0..size {
        for x in 0..size {
            let mut r_sum = 0u32;
            let mut g_sum = 0u32;
            let mut b_sum = 0u32;
            let mut a_sum = 0u32;
            for sy in 0..ss {
                for sx in 0..ss {
                    let src_x = x * ss + sx;
                    let src_y = y * ss + sy;
                    let idx = (src_y * draw_size + src_x) * 4;
                    r_sum += pixels[idx] as u32;
                    g_sum += pixels[idx + 1] as u32;
                    b_sum += pixels[idx + 2] as u32;
                    a_sum += pixels[idx + 3] as u32;
                }
            }
            let count = (ss * ss) as u32;
            let idx = (y * size + x) * 4;
            result[idx] = (r_sum / count) as u8;
            result[idx + 1] = (g_sum / count) as u8;
            result[idx + 2] = (b_sum / count) as u8;
            result[idx + 3] = (a_sum / count) as u8;
        }
    }

    image::RgbaImage::from_raw(size as u32, size as u32, result)
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
