//! Ripe Chroma -- DankMango's own wallpaper colour engine.
//!
//! Reads a wallpaper (or a single seed colour), works out what colour it
//! actually is, and writes a DankMaterialShell custom-theme palette from it.
//!
//! Run event-driven off a wallpaper change, never as a daemon -- a full 4K
//! wallpaper costs about a tenth of a second end to end.

mod extract;
mod generate;
mod output;

use generate::{Mode, Scheme};

const USAGE: &str = "\
dankmango-ripe-chroma -- wallpaper -> DankMaterialShell palette

USAGE:
    dankmango-ripe-chroma --wallpaper <path> [--count <N>] [--mode <M>] [--output <path>]
    dankmango-ripe-chroma --seed <hexcolor> [--mode <M>] [--output <path>]

INPUT (exactly one):
    -w, --wallpaper <path>   Image to extract the palette from.
    -s, --seed <hexcolor>    Single colour (#rrggbb) to generate from; skips
                             extraction entirely.

OPTIONS:
    -c, --count <N>          Colours to extract, 3-8. Default 5. More clusters
                             means a better chance the secondary and tertiary
                             roles come from the wallpaper rather than from a
                             hue rotation. Ignored with --seed.
    -m, --mode <M>           accurate | vibrant | muted. Default accurate.
                               accurate  hue-faithful; lightness gives way so
                                         the wallpaper's real hue survives.
                               vibrant   pushes chroma to the gamut cusp.
                               muted     softer, closest to Matugen's own look.
    -o, --output <path>      Where to write the palette, as DMS's custom-theme
                             {\"dark\":{..},\"light\":{..}} document -- both schemes
                             are always generated. Default: DMS's
                             configured customThemeFile if it has one, else
                             ~/.config/DankMaterialShell/dankmango-theme.json.
                             Use '-' for stdout.
    -h, --help               This text.
";

struct Args {
    wallpaper: Option<String>,
    seed: Option<String>,
    count: usize,
    mode: Mode,
    output: Option<String>,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args { wallpaper: None, seed: None, count: 5, mode: Mode::Accurate, output: None };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        // Every value-taking flag reports its own name when the value is
        // missing, because "missing argument" on its own is useless in a log.
        let mut value = |flag: &str| -> Result<String, String> {
            it.next().ok_or_else(|| format!("{flag} needs a value"))
        };
        match arg.as_str() {
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            "-w" | "--wallpaper" => args.wallpaper = Some(value("--wallpaper")?),
            "-s" | "--seed" => args.seed = Some(value("--seed")?),
            "-o" | "--output" => args.output = Some(value("--output")?),
            "-m" | "--mode" => args.mode = Mode::parse(&value("--mode")?)?,
            "-c" | "--count" => {
                let raw = value("--count")?;
                let n: usize = raw.parse().map_err(|_| format!("--count '{raw}' is not a number"))?;
                // Bounded rather than clamped silently: below 3 there aren't
                // enough colours to fill the supporting roles, and above 8 the
                // extra clusters are splitting noise.
                if !(3..=8).contains(&n) {
                    return Err(format!("--count must be 3-8, got {n}"));
                }
                args.count = n;
            }
            other => return Err(format!("unknown argument '{other}' (try --help)")),
        }
    }
    match (&args.wallpaper, &args.seed) {
        (None, None) => Err("need --wallpaper or --seed (try --help)".into()),
        (Some(_), Some(_)) => Err("--wallpaper and --seed are mutually exclusive".into()),
        _ => Ok(args),
    }
}

fn run() -> Result<String, String> {
    let args = parse_args()?;

    // Both input modes converge on the same cluster list, so generation and
    // output below never need to know which one was used.
    let clusters = match (&args.wallpaper, &args.seed) {
        (Some(path), _) => extract::from_image(path, args.count)?,
        (_, Some(hex)) => vec![generate::seed_cluster(hex)?],
        _ => unreachable!("parse_args guarantees exactly one input"),
    };

    // BOTH schemes, always. Light mode is not an option or a fourth mode -- it
    // is the other half of every palette this engine produces, so there is no
    // flag to forget and no way to end up with a half-written theme that makes
    // DMS's Light Mode toggle silently do nothing.
    let dark = generate::build(&clusters, args.mode, Scheme::Dark);
    let light = generate::build(&clusters, args.mode, Scheme::Light);

    match args.output.as_deref() {
        Some("-") => {
            output::write_stdout(&dark.roles, &light.roles);
            Ok(String::new())
        }
        other => {
            let path = other.map(std::path::PathBuf::from).unwrap_or_else(output::resolve_output);
            output::write(&path, &dark.roles, &light.roles)?;
            Ok(format!(
                "wrote {} roles x2 (dark + light) to {}",
                dark.roles.len(),
                path.display()
            ))
        }
    }
}

fn main() {
    match run() {
        Ok(msg) => {
            if !msg.is_empty() {
                println!("{msg}");
            }
        }
        Err(e) => {
            eprintln!("dankmango-ripe-chroma: {e}");
            std::process::exit(1);
        }
    }
}
