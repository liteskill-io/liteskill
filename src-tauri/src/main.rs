// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use tauri::menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::Manager;
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

/// Maximum time to wait for the Phoenix server to become reachable.
const SERVER_READY_TIMEOUT: Duration = Duration::from_secs(120);
/// Poll interval when checking server readiness.
const SERVER_READY_POLL: Duration = Duration::from_millis(200);
/// Time to wait for sidecar to shut down gracefully before force-killing.
const GRACEFUL_SHUTDOWN_TIMEOUT: Duration = Duration::from_millis(3000);
/// Preferred ports for the Phoenix sidecar, tried in order. Using a well-known
/// port keeps the OAuth callback URL consistent across launches, which avoids
/// 409 conflicts on providers like OpenRouter that auto-register apps by origin.
const PREFERRED_PORTS: &[u16] = &[4000, 3000, 5173];

struct AppState {
    sidecar_child: Mutex<Option<SidecarProcess>>,
    /// Set once shutdown has been initiated to avoid double-kill.
    shutting_down: AtomicBool,
}

struct SidecarProcess {
    child: Option<tauri_plugin_shell::process::CommandChild>,
    pid: Option<u32>,
}

impl Drop for SidecarProcess {
    fn drop(&mut self) {
        if let Some(child) = self.child.take() {
            let _ = child.kill();
        }
    }
}

/// Opens a URL in the user's default system browser.
fn open_in_system_browser(url: &str) {
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("xdg-open").arg(url).spawn();
    }
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open").arg(url).spawn();
    }
    #[cfg(target_os = "windows")]
    {
        let _ = std::process::Command::new("cmd")
            .args(["/C", "start", "", url])
            .spawn();
    }
}

/// Attempts graceful sidecar shutdown, then falls back to a hard kill.
/// Idempotent — only the first caller actually performs the shutdown.
fn kill_sidecar(app: &tauri::AppHandle) {
    let Some(state) = app.try_state::<AppState>() else {
        return;
    };

    // Ensure we only run shutdown logic once.
    if state.shutting_down.swap(true, Ordering::SeqCst) {
        return;
    }

    let Ok(mut guard) = state.sidecar_child.lock() else {
        return;
    };
    let Some(mut process) = guard.take() else {
        return;
    };

    if let Some(pid) = process.pid {
        println!("Attempting graceful shutdown of sidecar (PID: {pid})...");

        #[cfg(unix)]
        {
            use std::process::Command;
            let _ = Command::new("kill")
                .args(["-TERM", &pid.to_string()])
                .output();

            let start = std::time::Instant::now();
            while start.elapsed() < GRACEFUL_SHUTDOWN_TIMEOUT {
                let status = Command::new("kill").args(["-0", &pid.to_string()]).output();
                if let Ok(output) = status {
                    if !output.status.success() {
                        println!("Sidecar shut down gracefully");
                        return;
                    }
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            println!("Graceful shutdown timeout, forcing kill...");
        }

        #[cfg(windows)]
        {
            // On Windows, use taskkill for graceful shutdown (sends WM_CLOSE / ctrl-break).
            use std::process::Command;
            let _ = Command::new("taskkill")
                .args(["/PID", &pid.to_string()])
                .output();

            let start = std::time::Instant::now();
            while start.elapsed() < GRACEFUL_SHUTDOWN_TIMEOUT {
                // tasklist /FI filters by PID — exit code 0 means process found.
                let status = Command::new("tasklist")
                    .args(["/FI", &format!("PID eq {pid}"), "/NH"])
                    .output();
                if let Ok(output) = status {
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    if !stdout.contains(&pid.to_string()) {
                        println!("Sidecar shut down gracefully");
                        return;
                    }
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            println!("Graceful shutdown timeout, forcing kill...");

            // Force kill as fallback.
            let _ = Command::new("taskkill")
                .args(["/F", "/PID", &pid.to_string()])
                .output();
        }
    }

    // Fallback: SIGKILL via Tauri's child.kill().
    if let Some(child) = process.child.take() {
        println!("Force-killing sidecar...");
        let _ = child.kill();
    }
}

/// Builds the native application menu (File, Edit, View, Help).
fn build_app_menu(app: &tauri::AppHandle) -> Result<tauri::menu::Menu<tauri::Wry>, tauri::Error> {
    let file_menu = SubmenuBuilder::new(app, "File")
        .item(
            &MenuItemBuilder::with_id("new_conversation", "New Conversation")
                .accelerator("CmdOrCtrl+N")
                .build(app)?,
        )
        .separator()
        .item(&PredefinedMenuItem::close_window(app, None)?)
        .build()?;

    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .item(&PredefinedMenuItem::undo(app, None)?)
        .item(&PredefinedMenuItem::redo(app, None)?)
        .separator()
        .item(&PredefinedMenuItem::cut(app, None)?)
        .item(&PredefinedMenuItem::copy(app, None)?)
        .item(&PredefinedMenuItem::paste(app, None)?)
        .item(&PredefinedMenuItem::select_all(app, None)?)
        .build()?;

    let view_menu = SubmenuBuilder::new(app, "View")
        .item(
            &MenuItemBuilder::with_id("toggle_sidebar", "Toggle Sidebar")
                .accelerator("CmdOrCtrl+B")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("toggle_command_palette", "Command Palette")
                .accelerator("CmdOrCtrl+K")
                .build(app)?,
        )
        .build()?;

    let help_menu = SubmenuBuilder::new(app, "Help")
        .item(&MenuItemBuilder::with_id("about", "About Liteskill").build(app)?)
        .build()?;

    MenuBuilder::new(app)
        .item(&file_menu)
        .item(&edit_menu)
        .item(&view_menu)
        .item(&help_menu)
        .build()
}

/// Sets up the system tray icon with Show/Quit menu.
fn setup_tray(app: &tauri::App) -> Result<(), tauri::Error> {
    let show_item = MenuItemBuilder::with_id("tray_show", "Show Liteskill").build(app)?;
    let quit_item = MenuItemBuilder::with_id("tray_quit", "Quit").build(app)?;
    let tray_menu = MenuBuilder::new(app)
        .item(&show_item)
        .separator()
        .item(&quit_item)
        .build()?;

    TrayIconBuilder::new()
        .icon(app.default_window_icon().unwrap().clone())
        .menu(&tray_menu)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "tray_show" => {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.show();
                    let _ = w.set_focus();
                }
            }
            "tray_quit" => {
                kill_sidecar(app);
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.show();
                    let _ = w.unminimize();
                    let _ = w.set_focus();
                }
            }
        })
        .build(app)?;

    Ok(())
}

#[tauri::command]
async fn open_file_dialog(
    title: String,
    filters: Vec<(String, Vec<String>)>,
) -> Result<Option<String>, String> {
    let mut dialog = rfd::AsyncFileDialog::new().set_title(&title);
    for (name, exts) in &filters {
        let ext_refs: Vec<&str> = exts.iter().map(|s| s.as_str()).collect();
        dialog = dialog.add_filter(name, &ext_refs);
    }
    let file = dialog.pick_file().await;
    Ok(file.map(|f| f.path().to_string_lossy().to_string()))
}

#[tauri::command]
async fn save_file_dialog(title: String, default_name: String) -> Result<Option<String>, String> {
    let dialog = rfd::AsyncFileDialog::new()
        .set_title(&title)
        .set_file_name(&default_name);
    let file = dialog.save_file().await;
    Ok(file.map(|f| f.path().to_string_lossy().to_string()))
}

/// Returns true when LITESKILL_DEV=true — skip sidecar, connect to
/// an already-running Phoenix dev server on port 4000 instead.
fn dev_mode() -> bool {
    std::env::var("LITESKILL_DEV").unwrap_or_default() == "true"
}

fn main() {
    // Work around WebKitGTK DMA-BUF rendering issues on Linux.
    // The DMA-BUF renderer can crash with "Could not create default EGL display"
    // on certain GPU/driver combinations. The primary fix is stripping bundled
    // libwayland-*.so from the AppImage (done at build time); this env var
    // provides an additional safety net.
    #[cfg(target_os = "linux")]
    {
        if std::env::var("WEBKIT_DISABLE_DMABUF_RENDERER").is_err() {
            std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        }
    }

    // generate_context! emits a global static symbol (_EMBED_INFO_PLIST) and
    // must be called exactly once per binary. Calling it inside both
    // run_dev_mode and run_production_mode causes a duplicate-symbol linker
    // error because both functions are compiled regardless of which branch runs.
    let context = tauri::generate_context!();
    if dev_mode() {
        run_dev_mode(context);
    } else {
        run_production_mode(context);
    }
}

/// Dev mode: no sidecar, just a window pointed at localhost:4000.
fn run_dev_mode(context: tauri::Context<tauri::Wry>) {
    let port: u16 = std::env::var("LITESKILL_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(4000);

    println!("Dev mode: connecting to existing Phoenix server on port {port}");

    tauri::Builder::default()
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(tauri_plugin_log::log::LevelFilter::Info)
                .build(),
        )
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .invoke_handler(tauri::generate_handler![open_file_dialog, save_file_dialog])
        .setup(move |app| {
            let url = format!("http://localhost:{port}");
            let builder = tauri::WebviewWindowBuilder::new(
                app,
                "main",
                tauri::WebviewUrl::External(url.parse().unwrap()),
            )
            .title("Liteskill (dev)")
            .inner_size(1280.0, 900.0)
            .resizable(true)
            .on_navigation(|url| {
                // Allow navigation to localhost only; open anything else in the
                // system browser so the Tauri webview is never hijacked.
                match url.host_str() {
                    Some("localhost") | Some("127.0.0.1") => true,
                    _ => {
                        println!("Opening external URL in system browser: {url}");
                        open_in_system_browser(url.as_str());
                        false
                    }
                }
            });

            let window = builder.build()?;

            // Set native menu on the window
            if let Ok(menu) = build_app_menu(app.handle()) {
                let _ = window.set_menu(menu);
            }

            // System tray
            setup_tray(app)?;

            Ok(())
        })
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            match id {
                "new_conversation" | "toggle_sidebar" | "toggle_command_palette" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.eval(&format!(
                            "window.dispatchEvent(new CustomEvent('tauri:menu', {{ detail: {{ action: '{}' }} }}))",
                            id
                        ));
                    }
                }
                id if id == "quit" || id.contains("quit") => {
                    kill_sidecar(app);
                    app.exit(0);
                }
                _ => {}
            }
        })
        .run(context)
        .expect("error while running tauri application");
}

/// Production mode: start the Burrito sidecar, wait for it, open a window.
fn run_production_mode(context: tauri::Context<tauri::Wry>) {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(tauri_plugin_log::log::LevelFilter::Info)
                .build(),
        )
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .invoke_handler(tauri::generate_handler![open_file_dialog, save_file_dialog])
        .manage(AppState {
            sidecar_child: Mutex::new(None),
            shutting_down: AtomicBool::new(false),
        })
        .setup(|app| {
            // System tray (set up before server start — shows icon immediately)
            setup_tray(app)?;

            let port = match find_free_port() {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("Failed to find free port: {e}");
                    rfd::MessageDialog::new()
                        .set_title("Liteskill - Startup Error")
                        .set_description(&format!(
                            "Failed to find a free port:\n\n{e}\n\nThe application will now exit."
                        ))
                        .set_level(rfd::MessageLevel::Error)
                        .show();
                    std::process::exit(1);
                }
            };
            println!("Using port {port} for Phoenix server");

            if let Err(e) = start_server(app.handle(), port) {
                eprintln!("Failed to start sidecar: {e}");
                rfd::MessageDialog::new()
                    .set_title("Liteskill - Startup Error")
                    .set_description(&format!(
                        "Failed to start the application server:\n\n{e}\n\nThe application will now exit."
                    ))
                    .set_level(rfd::MessageLevel::Error)
                    .show();
                std::process::exit(1);
            }

            // Move the blocking server-readiness check and window creation to a
            // background thread. On macOS, the setup closure runs inside
            // applicationDidFinishLaunching: which MUST return quickly — blocking
            // the main thread causes macOS to terminate the app with SIGABRT.
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                if let Err(e) = check_server_started(port) {
                    eprintln!("Server failed to become ready: {e}");
                    kill_sidecar(&handle);
                    rfd::MessageDialog::new()
                        .set_title("Liteskill - Startup Error")
                        .set_description(&format!(
                            "The application server did not start in time:\n\n{e}\n\nThe application will now exit."
                        ))
                        .set_level(rfd::MessageLevel::Error)
                        .show();
                    handle.exit(1);
                    return;
                }

                // Create the main window pointing at the dynamic port.
                // Window is NOT defined in tauri.conf.json — we build it here so
                // the URL reflects whichever port the OS assigned.
                // Tauri handles cross-thread window creation via IPC to the main
                // thread's event loop, so this is safe from a background thread.
                let url = format!("http://localhost:{port}");
                let builder = tauri::WebviewWindowBuilder::new(
                    &handle,
                    "main",
                    tauri::WebviewUrl::External(url.parse().unwrap()),
                )
                .title("Liteskill")
                .inner_size(1280.0, 900.0)
                .resizable(true)
                .on_navigation(|url| {
                    // Allow navigation to localhost only; open anything else in
                    // the system browser so the Tauri webview is never hijacked.
                    match url.host_str() {
                        Some("localhost") | Some("127.0.0.1") => true,
                        _ => {
                            println!("Opening external URL in system browser: {url}");
                            open_in_system_browser(url.as_str());
                            false
                        }
                    }
                });

                match builder.build() {
                    Ok(window) => {
                        // Set native menu on the window
                        if let Ok(menu) = build_app_menu(&handle) {
                            let _ = window.set_menu(menu);
                        }
                    }
                    Err(e) => {
                        eprintln!("Failed to create window: {e}");
                        kill_sidecar(&handle);
                        handle.exit(1);
                    }
                }
            });

            Ok(())
        })
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            match id {
                "new_conversation" | "toggle_sidebar" | "toggle_command_palette" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.eval(&format!(
                            "window.dispatchEvent(new CustomEvent('tauri:menu', {{ detail: {{ action: '{}' }} }}))",
                            id
                        ));
                    }
                }
                id if id == "quit" || id.contains("quit") => {
                    println!("Quit menu item triggered, shutting down gracefully...");
                    kill_sidecar(app);
                    app.exit(0);
                }
                _ => {}
            }
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                kill_sidecar(&window.app_handle());
            }
        })
        .build(context)
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                println!("ExitRequested event received, shutting down...");
                kill_sidecar(app_handle);
                // Do NOT call prevent_exit — let Tauri's normal exit proceed
                // after the sidecar has been cleaned up.
            }
        });
}

fn start_server(app: &tauri::AppHandle, port: u16) -> Result<(), String> {
    let sidecar_command = app
        .shell()
        .sidecar("desktop")
        .map_err(|e| format!("Failed to set up sidecar: {e}"))?
        .env("LITESKILL_DESKTOP", "true")
        .env("PORT", port.to_string())
        // LC_ALL=C prevents macOS locale subsystem from spawning threads.
        // PG 18 aborts with "postmaster became multithreaded during startup"
        // if setlocale() triggers thread creation. Setting it here ensures
        // ALL child processes (BEAM, pg_ctl, postgres) inherit it.
        .env("LC_ALL", "C");

    let (mut rx, child) = sidecar_command
        .spawn()
        .map_err(|e| format!("Failed to spawn sidecar: {e}"))?;

    let pid = child.pid();
    println!("Sidecar process started with PID: {pid}");

    if let Some(state) = app.try_state::<AppState>() {
        if let Ok(mut guard) = state.sidecar_child.lock() {
            *guard = Some(SidecarProcess {
                child: Some(child),
                pid: Some(pid),
            });
        }
    }

    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(line_bytes) => {
                    let line = String::from_utf8_lossy(&line_bytes);
                    println!("{line}");
                }
                CommandEvent::Stderr(line_bytes) => {
                    let line = String::from_utf8_lossy(&line_bytes);
                    eprintln!("[sidecar stderr] {line}");
                }
                _ => {}
            }
        }
    });

    Ok(())
}

/// Tries each port in `PREFERRED_PORTS` in order, then falls back to an
/// OS-assigned ephemeral port.
fn find_free_port() -> Result<u16, String> {
    for &port in PREFERRED_PORTS {
        if let Ok(listener) = TcpListener::bind(("127.0.0.1", port)) {
            drop(listener);
            return Ok(port);
        }
        println!("Port {port} is in use, trying next...");
    }
    println!("All preferred ports in use, finding an ephemeral port...");
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("Failed to bind to ephemeral port: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("Failed to get local address: {e}"))?
        .port();
    Ok(port)
}

/// Polls TCP connection until the Phoenix server is reachable on the given port.
/// Returns an error if the server doesn't start within `SERVER_READY_TIMEOUT`.
fn check_server_started(port: u16) -> Result<(), String> {
    let addr = format!("localhost:{port}");
    println!("Waiting for Phoenix server to start on {addr}...");

    let start = std::time::Instant::now();
    loop {
        if std::net::TcpStream::connect(&addr).is_ok() {
            println!("Phoenix server is ready");
            return Ok(());
        }
        if start.elapsed() >= SERVER_READY_TIMEOUT {
            return Err(format!(
                "Server did not become reachable at {addr} within {}s",
                SERVER_READY_TIMEOUT.as_secs()
            ));
        }
        std::thread::sleep(SERVER_READY_POLL);
    }
}
