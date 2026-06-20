// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.contains(&"--version".to_string()) || args.contains(&"-v".to_string()) {
        println!("ClipHist {}", env!("CARGO_PKG_VERSION"));
        std::process::exit(0);
    }

    // --- Evdev helper mode (Linux only) ---
    // Invoked via: pkexec cliphist --evdev-helper --key Ctrl
    //               --socket /tmp/cliphist-dtap.sock
    //               --wayland-display wayland-0
    //               --xdg-runtime-dir /run/user/1000
    #[cfg(target_os = "linux")]
    {
        if args.iter().any(|a| a == "--evdev-helper") {
            let get_arg = |name: &str| -> String {
                args.iter()
                    .position(|a| a == name)
                    .and_then(|i| args.get(i + 1))
                    .cloned()
                    .unwrap_or_else(|| {
                        eprintln!("Missing {} argument", name);
                        std::process::exit(1);
                    })
            };

            let key = get_arg("--key");
            let socket = get_arg("--socket");
            let wayland_display = get_arg("--wayland-display");
            let xdg_runtime_dir = get_arg("--xdg-runtime-dir");

            tauri_app_lib::evdev_helper::run(
                &key,
                &socket,
                &wayland_display,
                &xdg_runtime_dir,
            );
            // run() never returns
        }
    }

    tauri_app_lib::run()
}
