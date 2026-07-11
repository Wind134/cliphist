//! Icon generator for ClipHist.
//! Generates all required icon files from pure pixel drawing.
//! Design: clipboard with integrated clock face on indigo-purple bg.
use std::fs::File;
use std::io::{BufWriter, Cursor, Write};
use std::path::PathBuf;

fn main() {
    let dir = PathBuf::from("icons");
    std::fs::create_dir_all(&dir).unwrap();
    for (&s, n) in SIZES.iter().zip(NAMES.iter()) {
        draw_icon(s).save(&dir.join(n)).unwrap();
        println!("Generated {}", dir.join(n).display());
    }
    for &(s, n) in STORE {
        draw_icon(s).save(&dir.join(n)).unwrap();
    }
    let pngs: Vec<Vec<u8>> = ICO_SIZES.iter().map(|&s| {
        let mut b = Vec::new();
        draw_icon(s).write_to(&mut Cursor::new(&mut b), image::ImageFormat::Png).unwrap();
        b
    }).collect();
    write_ico(&dir.join("icon.ico"), &pngs, &ICO_SIZES).unwrap();
    draw_icon(256).save_with_format(dir.join("icon.icns"), image::ImageFormat::Png).unwrap();
    println!("Done");
}

const SIZES: &[usize] = &[16, 32, 48, 128, 256];
const NAMES: &[&str] = &["icon.png", "32x32.png", "48x48.png", "128x128.png", "128x128@2x.png"];
const ICO_SIZES: &[usize] = &[16, 32, 48, 256];
const STORE: &[(usize, &str)] = &[
    (30, "Square30x30Logo.png"), (44, "Square44x44Logo.png"),
    (50, "StoreLogo.png"), (71, "Square71x71Logo.png"),
    (89, "Square89x89Logo.png"), (107, "Square107x107Logo.png"),
    (142, "Square142x142Logo.png"), (150, "Square150x150Logo.png"),
    (284, "Square284x284Logo.png"), (310, "Square310x310Logo.png"),
];

fn draw_icon(size: usize) -> image::RgbaImage {
    let ss = 2;
    let ds = size * ss;
    let sc = ds as f32 / 64.0;
    let mut px = vec![0u8; ds * ds * 4];
    // Background gradient: indigo #4F46E5 -> purple #7C3AED
    for y in 0..ds {
        for x in 0..ds {
            let t = ((x as f32/ds as f32)*0.55 + (y as f32/ds as f32)*0.45).min(1.0);
            let i = (y*ds+x)*4;
            px[i] = (0x4Fu8 as f32 + (0x7C-0x4F) as f32*t) as u8;
            px[i+1] = (0x46u8 as f32 + (0x3A-0x46) as f32*t) as u8;
            px[i+2] = (0xE5u8 as f32 + (0xED-0xE5) as f32*t) as u8;
            px[i+3] = 255;
        }
    }
    // Background rounded corners (radius 12)
    let bcr = 12.0 * sc;
    for y in 0..ds {
        for x in 0..ds {
            let dl = (0.0 - x as f32).max(0.0);
            let dr = (x as f32 - (ds-1) as f32).max(0.0);
            let dt = (0.0 - y as f32).max(0.0);
            let db = (y as f32 - (ds-1) as f32).max(0.0);
            let d = (dl.max(dr).powi(2) + dt.max(db).powi(2)).sqrt() - bcr;
            if d > 0.0 {
                let a = if d >= 1.0 { 0.0 } else { 1.0 - d * 0.5 };
                px[(y*ds+x)*4+3] = (px[(y*ds+x)*4+3] as f32 * a) as u8;
            }
        }
    }
    // Helper macros
    macro_rules! setp { ($x:expr,$y:expr,$r:expr,$g:expr,$b:expr,$a:expr) => {
        if $x>=0 && $y>=0 && $x<ds as i64 && $y<ds as i64 {
            let i_ = ($y as usize*ds+$x as usize)*4;
            let ia = 1.0 - $a;
            px[i_] = ($r as f32*$a + px[i_] as f32*ia) as u8;
            px[i_+1] = ($g as f32*$a + px[i_+1] as f32*ia) as u8;
            px[i_+2] = ($b as f32*$a + px[i_+2] as f32*ia) as u8;
            px[i_+3] = px[i_+3].max(($a*255.0) as u8);
        }
    };}
    macro_rules! rrect { ($x0:expr,$y0:expr,$x1:expr,$y1:expr,$cr:expr,$r:expr,$g:expr,$b:expr,$a:expr) => {
        let sx = ($x0*sc).floor() as i64; let sy = ($y0*sc).floor() as i64;
        let ex = ($x1*sc).ceil() as i64; let ey = ($y1*sc).ceil() as i64;
        let rs = $cr*sc; let al = $a as f32/255.0;
        for py in sy..=ey { for px_ in sx..=ex {
            let dl_ = ($x0*sc - px_ as f32).max(0.0);
            let dr_ = (px_ as f32 - $x1*sc).max(0.0);
            let dt_ = ($y0*sc - py as f32).max(0.0);
            let db_ = (py as f32 - $y1*sc).max(0.0);
            let d_ = (dl_.max(dr_).powi(2) + dt_.max(db_).powi(2)).sqrt() - rs;
            let aa = if d_<=-1.0{1.0}else if d_>=1.0{0.0}else{0.5-d_*0.5};
            if aa>0.0 { setp!(px_, py, $r, $g, $b, al*aa); }
        }}
    };}
    // Shadow under clipboard
    rrect!(14.0, 13.0, 51.0, 57.0, 6.0, 0, 0, 0, 25);
    // Clipboard body (white)
    rrect!(13.0, 12.0, 51.0, 56.0, 6.0, 255, 255, 255, 255);
    // Clip arc at top (sampled as line segments)
    for i in 0..20 {
        let t1 = std::f32::consts::PI * (i as f32)/20.0 + std::f32::consts::PI;
        let t2 = std::f32::consts::PI * ((i+1) as f32)/20.0 + std::f32::consts::PI;
        let x1 = (32.0 + t1.cos()*10.0)*sc; let y1 = (10.0 + t1.sin()*5.0)*sc;
        let x2 = (32.0 + t2.cos()*10.0)*sc; let y2 = (10.0 + t2.sin()*5.0)*sc;
        let t = (3.0*sc).max(1.0)*0.5;
        let lsq = (x2-x1)*(x2-x1)+(y2-y1)*(y2-y1);
        let mix = (x1.min(x2)-t-1.0).floor() as i64;
        let mxx = (x1.max(x2)+t+1.0).ceil() as i64;
        let miy = (y1.min(y2)-t-1.0).floor() as i64;
        let mxy = (y1.max(y2)+t+1.0).ceil() as i64;
        for py in miy..=mxy { for px_ in mix..=mxx {
            let fx = px_ as f32+0.5; let fy = py as f32+0.5;
            let tp = if lsq>0.0{((fx-x1)*(x2-x1)+(fy-y1)*(y2-y1))/lsq}else{0.0};
            let tc = tp.max(0.0).min(1.0);
            let d = ((fx-(x1+tc*(x2-x1)))*(fx-(x1+tc*(x2-x1)))+(fy-(y1+tc*(y2-y1)))*(fy-(y1+tc*(y2-y1)))).sqrt()-t;
            let aa = if d<=-1.0{1.0}else if d>=1.0{0.0}else{0.5-d*0.5};
            if aa>0.0 { setp!(px_, py, 255,255,255, aa); }
        }}
    }
    // Clip inner hole (restore background gradient)
    for py in (6.0*sc).floor() as i64..=(14.0*sc).ceil() as i64 {
        for px_ in (26.0*sc).floor() as i64..=(38.0*sc).ceil() as i64 {
            let t = ((px_ as f32/ds as f32)*0.55 + (py as f32/ds as f32)*0.45).min(1.0);
            let i_ = (py as usize*ds+px_ as usize)*4;
            px[i_] = (0x4Fu8 as f32+(0x7C-0x4F) as f32*t) as u8;
            px[i_+1] = (0x46u8 as f32+(0x3A-0x46) as f32*t) as u8;
            px[i_+2] = (0xE5u8 as f32+(0xED-0xE5) as f32*t) as u8;
            px[i_+3] = 255;
        }
    }
    // Clock face: fill light gray
    let ccx = 32.0*sc; let ccy = 36.0*sc; let cr = 11.0*sc; let cri = cr.ceil() as i64;
    for dy in -cri..=cri { for dx_ in -cri..=cri {
        let d = ((dx_*dx_+dy*dy) as f32).sqrt();
        let dd = d - cr;
        let aa = if dd<=-1.0{1.0}else if dd>=1.0{0.0}else{1.0+dd*0.5};
        if aa>0.0 { setp!((ccx+dx_ as f32) as i64, (ccy+dy as f32) as i64, 243,244,246, aa); }
    }}
    // Clock border ring
    for dy in -cri..=cri { for dx_ in -cri..=cri {
        let d = ((dx_*dx_+dy*dy) as f32).sqrt();
        let do_ = d-cr; let di = d-(cr-2.0*sc);
        if do_<=0.0 && di>=0.0 {
            let ai = if di<=-1.0{1.0}else if di>=1.0{0.0}else{0.5-di*0.5};
            let ao = if do_<=-1.0{1.0}else if do_>=1.0{0.0}else{0.5+do_*0.5};
            let aa = ai*ao;
            if aa>0.0 { setp!((ccx+dx_ as f32) as i64, (ccy+dy as f32) as i64, 229,231,235, aa*0.8); }
        }
    }}
    // Tick marks at 12,3,6,9 (bold indigo)
    let (cxc, cyc, rc) = (32.0, 36.0, 11.0);
    rrect!(cxc-1.0, cyc-rc+1.5, cxc+1.0, cyc-rc+1.5+3.0, 0.0, 0x4F,0x46,0xE5, 220);
    rrect!(cxc-1.0, cyc+rc-1.5-3.0, cxc+1.0, cyc+rc-1.5, 0.0, 0x4F,0x46,0xE5, 220);
    rrect!(cxc+rc-1.5-3.0, cyc-1.0, cxc+rc-1.5, cyc+1.0, 0.0, 0x4F,0x46,0xE5, 220);
    rrect!(cxc-rc+1.5, cyc-1.0, cxc-rc+1.5+3.0, cyc+1.0, 0.0, 0x4F,0x46,0xE5, 220);
    // Small tick marks at other hours (only at >=32px for visibility)
    if size >= 32 {
        for h in [1.0,2.0,4.0,5.0,7.0,8.0,10.0,11.0] {
            let a = std::f32::consts::PI * (h-3.0)/6.0;
            let ri = rc-1.5-2.0; let ro_ = rc-1.5;
            let x1 = (cxc+a.cos()*ri)*sc; let y1 = (cyc+a.sin()*ri)*sc;
            let x2 = (cxc+a.cos()*ro_)*sc; let y2 = (cyc+a.sin()*ro_)*sc;
            let t = (1.0*sc).max(1.0)*0.5;
            let lsq = (x2-x1)*(x2-x1)+(y2-y1)*(y2-y1);
            let mix = (x1.min(x2)-t-1.0).floor() as i64;
            let mxx = (x1.max(x2)+t+1.0).ceil() as i64;
            let miy = (y1.min(y2)-t-1.0).floor() as i64;
            let mxy = (y1.max(y2)+t+1.0).ceil() as i64;
            for py in miy..=mxy { for px_ in mix..=mxx {
                let fx = px_ as f32+0.5; let fy = py as f32+0.5;
                let tp = if lsq>0.0{((fx-x1)*(x2-x1)+(fy-y1)*(y2-y1))/lsq}else{0.0};
                let tc = tp.max(0.0).min(1.0);
                let d = ((fx-(x1+tc*(x2-x1)))*(fx-(x1+tc*(x2-x1)))+(fy-(y1+tc*(y2-y1)))*(fy-(y1+tc*(y2-y1)))).sqrt()-t;
                let aa = if d<=-1.0{1.0}else if d>=1.0{0.0}else{0.5-d*0.5};
                if aa>0.0 { setp!(px_, py, 0xA5,0xB4,0xFC, aa*0.63); }
            }}
        }
        // Hour hand (~10 o'clock, indigo)
        let ha = std::f32::consts::PI * 10.0/6.0;
        let hx1 = (cxc+ha.cos()*5.5)*sc; let hy1 = (cyc+ha.sin()*5.5)*sc;
        let ht = (2.5*sc).max(1.0)*0.5;
        let hlsq = (hx1-ccx)*(hx1-ccx)+(hy1-ccy)*(hy1-ccy);
        let hmix = (ccx.min(hx1)-ht-1.0).floor() as i64;
        let hmxx = (ccx.max(hx1)+ht+1.0).ceil() as i64;
        let hmiy = (ccy.min(hy1)-ht-1.0).floor() as i64;
        let hmxy = (ccy.max(hy1)+ht+1.0).ceil() as i64;
        for py in hmiy..=hmxy { for px_ in hmix..=hmxx {
            let fx = px_ as f32+0.5; let fy = py as f32+0.5;
            let tp = if hlsq>0.0{((fx-ccx)*(hx1-ccx)+(fy-ccy)*(hy1-ccy))/hlsq}else{0.0};
            let tc = tp.max(0.0).min(1.0);
            let d = ((fx-(ccx+tc*(hx1-ccx)))*(fx-(ccx+tc*(hx1-ccx)))+(fy-(ccy+tc*(hy1-ccy)))*(fy-(ccy+tc*(hy1-ccy)))).sqrt()-ht;
            let aa = if d<=-1.0{1.0}else if d>=1.0{0.0}else{0.5-d*0.5};
            if aa>0.0 { setp!(px_, py, 0x4F,0x46,0xE5, aa*0.9); }
        }}
        // Minute hand (~2 o'clock, warm amber accent)
        let ma_ = std::f32::consts::PI * 2.0/6.0;
        let mx1 = (cxc+ma_.cos()*7.5)*sc; let my1 = (cyc+ma_.sin()*7.5)*sc;
        let mt = (2.0*sc).max(1.0)*0.5;
        let mlsq = (mx1-ccx)*(mx1-ccx)+(my1-ccy)*(my1-ccy);
        let mmix = (ccx.min(mx1)-mt-1.0).floor() as i64;
        let mmxx = (ccx.max(mx1)+mt+1.0).ceil() as i64;
        let mmiy = (ccy.min(my1)-mt-1.0).floor() as i64;
        let mmxy = (ccy.max(my1)+mt+1.0).ceil() as i64;
        for py in mmiy..=mmxy { for px_ in mmix..=mmxx {
            let fx = px_ as f32+0.5; let fy = py as f32+0.5;
            let tp = if mlsq>0.0{((fx-ccx)*(mx1-ccx)+(fy-ccy)*(my1-ccy))/mlsq}else{0.0};
            let tc = tp.max(0.0).min(1.0);
            let d = ((fx-(ccx+tc*(mx1-ccx)))*(fx-(ccx+tc*(mx1-ccx)))+(fy-(ccy+tc*(my1-ccy)))*(fy-(ccy+tc*(my1-ccy)))).sqrt()-mt;
            let aa = if d<=-1.0{1.0}else if d>=1.0{0.0}else{0.5-d*0.5};
            if aa>0.0 { setp!(px_, py, 0xF5,0x9E,0x0B, aa*0.9); }
        }}
        // Center dot (dark)
        let dr = 1.5*sc; let dri = dr.ceil() as i64;
        for dy in -dri..=dri { for dx_ in -dri..=dri {
            let d = ((dx_*dx_+dy*dy) as f32).sqrt();
            let dd = d - dr;
            let aa = if dd<=-1.0{1.0}else if dd>=1.0{0.0}else{0.5-dd*0.5};
            if aa>0.0 { setp!((ccx+dx_ as f32) as i64, (ccy+dy as f32) as i64, 0x1F,0x29,0x37, aa*0.9); }
        }}
    }
    // Downsample from 2x to final size
    let mut out = vec![0u8; size*size*4];
    for y in 0..size {
        for x in 0..size {
            let (mut rs, mut gs, mut bs, mut asum, mut ct) = (0u32,0u32,0u32,0u32,0u32);
            for sy in 0..ss { for sx in 0..ss {
                let i = ((y*ss+sy)*ds+(x*ss+sx))*4;
                rs += px[i] as u32; gs += px[i+1] as u32;
                bs += px[i+2] as u32; asum += px[i+3] as u32; ct += 1;
            }}
            let i = (y*size+x)*4;
            out[i] = (rs/ct) as u8; out[i+1] = (gs/ct) as u8;
            out[i+2] = (bs/ct) as u8; out[i+3] = (asum/ct) as u8;
        }
    }
    image::RgbaImage::from_raw(size as u32, size as u32, out).expect("create image")
}

fn write_ico(path: &PathBuf, pngs: &[Vec<u8>], sizes: &[usize]) -> std::io::Result<()> {
    use byteorder::{LittleEndian, WriteBytesExt};
    let n = pngs.len() as u16;
    let off = (6 + n as usize * 16) as u32;
    let mut f = BufWriter::new(File::create(path)?);
    f.write_u16::<LittleEndian>(0)?; f.write_u16::<LittleEndian>(1)?;
    f.write_u16::<LittleEndian>(n)?;
    let mut o = off;
    for (&sz, png) in sizes.iter().zip(pngs.iter()) {
        f.write_u8(if sz==256{0}else{sz as u8})?;
        f.write_u8(if sz==256{0}else{sz as u8})?;
        f.write_u8(0)?; f.write_u8(0)?;
        f.write_u16::<LittleEndian>(1)?; f.write_u16::<LittleEndian>(32)?;
        f.write_u32::<LittleEndian>(png.len() as u32)?;
        f.write_u32::<LittleEndian>(o)?;
        o += png.len() as u32;
    }
    for png in pngs { f.write_all(png)?; }
    Ok(())
}
