//! Stage 3: write the palette where DankMaterialShell will read it.
//!
//! The shape is DMS's "custom theme" file: a flat JSON object of role name ->
//! hex colour, plus the `name` key DMS labels the theme with. Confirmed against Theme.qml's dynamic-mode mapping (the 24 roles
//! below are exactly the ones it binds) and against `loadCustomTheme`, which
//! takes a flat object as-is when there is no `dark`/`light` wrapper.

use std::io::Write;
use std::path::{Path, PathBuf};

/// Where the palette goes when `--output` is not given and DMS has no custom
/// theme file configured yet.
const DEFAULT_OUTPUT: &str = ".config/DankMaterialShell/dankmango-theme.json";
const DMS_SETTINGS: &str = ".config/DankMaterialShell/settings.json";

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

fn expand_tilde(p: &str) -> PathBuf {
    match p.strip_prefix("~/") {
        Some(rest) => home().join(rest),
        None => PathBuf::from(p),
    }
}

/// Resolve the output path: DMS's currently configured custom theme file if it
/// has one, otherwise our default.
///
/// Deliberately reads the live setting rather than assuming a path -- if the
/// user has already pointed DMS at a theme file, that is the file that has to
/// change for anything to happen on screen. Note this only ever *reads*
/// settings.json; pointing DMS at the palette is the user's call, not ours.
pub fn resolve_output() -> PathBuf {
    let settings = home().join(DMS_SETTINGS);
    if let Ok(text) = std::fs::read_to_string(&settings)
        && let Ok(json) = serde_json::from_str::<serde_json::Value>(&text)
        && let Some(configured) = json.get("customThemeFile").and_then(|v| v.as_str())
        && !configured.trim().is_empty()
    {
        return expand_tilde(configured.trim());
    }
    home().join(DEFAULT_OUTPUT)
}

/// The theme's display name, written into the palette as DMS's `name` key.
///
/// DMS's Settings > Theme & Colors prints `Current Theme: <name>` by reading
/// this key off the loaded theme object; every one of its 21 stock themes has
/// one. Without it that line reads "Current Theme: undefined". It is not a
/// colour role, so it is added here at serialisation time rather than being
/// carried through the palette (which would inflate the "wrote N roles" count).
///
/// IT GOES INSIDE *EACH* BRANCH, NOT BESIDE THEM. Verified again against
/// Theme.qml's `loadCustomTheme` (line 1385): it does
///
///     baseColors = themeData[colorMode] || themeData.dark || themeData.light
///     ...
///     customThemeData = baseColors;
///
/// so once a dark/light wrapper exists, `customThemeData` becomes the *branch*
/// object and a `name` sitting at the top level is never read -- the theme label
/// would go back to "undefined" the moment the wrapper was introduced. DMS's own
/// stock themes do the same thing (StockThemes.js has "Blue" in DARK and
/// "Blue Light" in LIGHT). We keep one name for both, since it is one theme.
const THEME_NAME: &str = "DankMango";

/// Serialise one scheme's roles as a JSON object body, indented `pad` spaces.
///
/// Role order rather than sorted order, so a human diffing two palettes sees
/// accents, surfaces and semantics grouped the way they were generated. Keys are
/// compile-time literals and values are our own `#rrggbb` output, so neither can
/// need escaping.
fn branch(roles: &[(&'static str, String)], pad: &str) -> String {
    let mut out = String::new();
    let name_comma = if roles.is_empty() { "" } else { "," };
    out.push_str(&format!("{pad}  \"name\": \"{THEME_NAME}\"{name_comma}\n"));
    for (i, (k, v)) in roles.iter().enumerate() {
        let comma = if i + 1 == roles.len() { "" } else { "," };
        out.push_str(&format!("{pad}  \"{k}\": \"{v}\"{comma}\n"));
    }
    out
}

/// The full custom-theme document: DMS's `{"dark": {...}, "light": {...}}` shape.
///
/// Both branches are always written. A wrapper with only one branch is legal to
/// DMS (`themeData.dark || themeData.light` falls back), but it is exactly the
/// state that made Light Mode a no-op before this existed, so it is not a shape
/// this engine should ever emit.
fn to_json(dark: &[(&'static str, String)], light: &[(&'static str, String)]) -> String {
    let mut out = String::from("{\n");
    out.push_str("  \"dark\": {\n");
    out.push_str(&branch(dark, "  "));
    out.push_str("  },\n");
    out.push_str("  \"light\": {\n");
    out.push_str(&branch(light, "  "));
    out.push_str("  }\n");
    out.push_str("}\n");
    out
}

/// Write the palette atomically.
///
/// DMS watches this file (`FileView.watchChanges`) and reparses on every change,
/// so a partially-written file is a JSON parse error and a toast in the user's
/// face. Write-then-rename means the shell only ever sees a complete palette.
pub fn write(
    path: &Path,
    dark: &[(&'static str, String)],
    light: &[(&'static str, String)],
) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    let json = to_json(dark, light);

    let tmp = path.with_extension("json.tmp");
    {
        let mut f = std::fs::File::create(&tmp)
            .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
        f.write_all(json.as_bytes()).map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
        f.sync_all().map_err(|e| format!("cannot flush {}: {e}", tmp.display()))?;
    }
    std::fs::rename(&tmp, path)
        .map_err(|e| format!("cannot replace {}: {e}", path.display()))?;
    Ok(())
}

/// `--output -` writes the palette to stdout instead of a file.
pub fn write_stdout(dark: &[(&'static str, String)], light: &[(&'static str, String)]) {
    print!("{}", to_json(dark, light));
}
