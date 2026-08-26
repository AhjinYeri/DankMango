//! Stage 2: turn extracted colours into a full set of Material role colours.
//!
//! THE PROBLEM THIS EXISTS TO FIX
//! -----------------------------
//! Material You's HCT tonal system picks a *tone* (lightness) per role first and
//! asks for the seed hue at that tone second. For most hues that is fine. For red
//! and purple it is not: sRGB simply cannot make a light, saturated red. Ask for
//! red at tone 80 and the only thing that fits in the gamut is a pale, low-chroma
//! red -- salmon pink. Matugen's "preserve the seed" schemes (fidelity, content)
//! don't help, because the clipping happens after the seed is preserved.
//!
//! So this module inverts the priority. Hue is the thing a human recognises as
//! "the wallpaper's colour", so hue is held exactly, chroma is next, and the
//! target lightness is the part that gives way. When red can't be red at L=0.75,
//! we move to the lightness where red *can* be red rather than accepting pink.
//!
//! Structural roles (surfaces, backgrounds, outlines) do the opposite: their job
//! is legibility, so they keep their lightness and give up chroma. Hence "hybrid".

use palette::convert::IntoColorUnclamped;
use palette::{FromColor, IntoColor, LinSrgb, Oklab, Oklch, Srgb};

use crate::extract::Cluster;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Hue-faithful. Lightness yields so the true hue survives.
    Accurate,
    /// Push chroma everywhere, in the spirit of pywal/wallust's direct extraction.
    Vibrant,
    /// Let chroma clip the way Matugen's tonal-spot does, for the softer look.
    Muted,
}

impl Mode {
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "accurate" => Ok(Mode::Accurate),
            "vibrant" => Ok(Mode::Vibrant),
            "muted" => Ok(Mode::Muted),
            other => Err(format!("unknown mode '{other}' (accurate|vibrant|muted)")),
        }
    }

    /// The only thing that differs between modes: how much chroma to ask for, and
    /// what it is worth paying in lightness to get it.
    fn params(self) -> ModeParams {
        match self {
            // Ask for roughly the wallpaper's own saturation, and treat that as
            // worth a real lightness move. Tuned against the red case: at pull
            // 0.35 the move never triggered and primary landed on #fc7279, which
            // is within a hair of literal salmon (#fa8072) -- i.e. the bug.
            Mode::Accurate => ModeParams { chroma_gain: 1.15, chroma_pull: 0.12, l_latitude: 0.22, surface_chroma: 1.0 },
            // Ask for far more chroma than the image has and pay almost nothing
            // for it, which parks accents at the gamut cusp -- the most saturated
            // version of the hue sRGB can express, wherever that happens to sit.
            Mode::Vibrant => ModeParams { chroma_gain: 1.90, chroma_pull: 0.04, l_latitude: 0.30, surface_chroma: 1.9 },
            // Latitude 0 means lightness never moves, so whatever chroma survives
            // at the Material tone is what you get. That is exactly the mechanism
            // that produces salmon from red -- reproduced here on purpose.
            Mode::Muted => ModeParams { chroma_gain: 0.62, chroma_pull: 0.0, l_latitude: 0.0, surface_chroma: 0.7 },
        }
    }
}

#[derive(Clone, Copy)]
struct ModeParams {
    /// Multiplier on the seed's own chroma when asking for accent chroma.
    chroma_gain: f32,
    /// Exchange rate between lightness and chroma: how much chroma one unit of
    /// lightness drift has to buy before the drift is worth it. Low = chases
    /// saturation hard, high = stays near the Material tone.
    chroma_pull: f32,
    /// How far (in Oklab L) a role may drift from its target to keep its chroma.
    l_latitude: f32,
    /// Multiplier on the (deliberately tiny) chroma of surfaces and backgrounds.
    surface_chroma: f32,
}


/// Dark or light. NOT a fourth mode -- it is an independent dimension: every
/// mode (accurate/vibrant/muted) and every input (wallpaper/seed) has both.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scheme {
    Dark,
    Light,
}

/// The per-scheme lightness targets, and nothing else.
///
/// WHERE THESE NUMBERS COME FROM -- READ BEFORE CHANGING ANY OF THEM.
/// The light column is not invented here and is not an inversion of the dark
/// column. It is measured from DankMaterialShell's own stock themes
/// (Common/StockThemes.js), by converting all nine LIGHT themes' roles to Oklab
/// and taking the mean L per role. Standard deviation across the nine was
/// +/-0.001..0.03 on the whole surface family, so these are deliberate targets
/// in DMS, not incidental values -- which is exactly why they are worth copying
/// rather than re-deriving.
///
/// THE INTERESTING PART IS WHERE LIGHT IS *NOT* THE MIRROR OF DARK:
///   outline    dark 0.656 -> light 0.569. Only -0.087. A mirrored outline would
///              sit near 0.34 and read as a hard black hairline; DMS keeps it
///              mid-grey in both schemes because its job is the same in both.
///   primary    dark 0.764 -> light 0.539. It darkens, but nowhere near to
///              1-0.764. Accents stay accents.
///   containers dark ramp 0.180..0.340 spans 0.160; light ramp 0.988..0.908
///              spans only 0.080 -- HALF. Light UIs separate their tiers with
///              much smaller steps, because the eye resolves shade differences
///              far better up near white than down near black.
///   semantics  DMS's own light default for `error` is #B3261E (L=0.501,
///              C=0.178) against dark's #F2B8B5 (L=0.834, C=0.068) -- light
///              semantics sit DARK and *more* saturated, not less.
///
/// Everything above the lightness targets -- hue preservation, the gamut search,
/// the chroma/lightness trade in `resolve` -- is scheme-independent and is not
/// duplicated below. Light mode is these numbers fed through the same pipeline.
struct SchemeTargets {
    primary: f32,
    primary_container: f32,
    secondary: f32,
    secondary_container: f32,
    tertiary: f32,
    tertiary_container: f32,
    surface: f32,
    surface_text: f32,
    surface_variant: f32,
    surface_variant_text: f32,
    background: f32,
    background_text: f32,
    outline: f32,
    c_lowest: f32,
    c_low: f32,
    c_mid: f32,
    c_high: f32,
    c_highest: f32,
    /// Where the hue-fixed semantic roles (error/warning/info/success) sit.
    semantic_l: f32,
    /// Chroma asked for by semantics. Light mode wants more, per #B3261E above.
    semantic_gain: f32,
    /// Multiplier on every container's chroma. Dark containers are deep, still
    /// quite saturated blocks; light containers are pale washes -- measured
    /// chroma ratio to their own accent is 0.61 in dark but only 0.23 in light.
    container_chroma: f32,
    /// Chroma for the two text tints and the low/high ends of the surface ramp.
    text_chroma: f32,
    variant_text_chroma: f32,
}

impl Scheme {
    // No `parse` counterpart to Mode::parse on purpose: there is no --scheme
    // flag, because both schemes are always generated. Adding one would let a
    // caller emit a half-written theme, which is the exact failure this feature
    // exists to remove.
    fn targets(self) -> SchemeTargets {
        match self {
            // Unchanged from the original dark-only engine, deliberately: light
            // mode was added without moving a single dark-mode number, so an
            // existing palette regenerates byte-identical.
            Scheme::Dark => SchemeTargets {
                primary: 0.72,
                primary_container: 0.42,
                secondary: 0.74,
                secondary_container: 0.34,
                tertiary: 0.76,
                tertiary_container: 0.36,
                surface: 0.155,
                surface_text: 0.94,
                surface_variant: 0.285,
                surface_variant_text: 0.80,
                background: 0.135,
                background_text: 0.94,
                outline: 0.585,
                c_lowest: 0.105,
                c_low: 0.145,
                c_mid: 0.185,
                c_high: 0.235,
                c_highest: 0.285,
                semantic_l: 0.74,
                semantic_gain: 1.0,
                container_chroma: 1.0,
                text_chroma: 0.006,
                variant_text_chroma: 0.010,
            },
            Scheme::Light => SchemeTargets {
                primary: 0.54,
                primary_container: 0.94,
                secondary: 0.65,
                secondary_container: 0.92,
                tertiary: 0.66,
                tertiary_container: 0.93,
                surface: 0.982,
                surface_text: 0.23,
                surface_variant: 0.914,
                surface_variant_text: 0.40,
                background: 0.985,
                background_text: 0.225,
                outline: 0.57,
                c_lowest: 0.988,
                c_low: 0.954,
                c_mid: 0.947,
                c_high: 0.928,
                c_highest: 0.908,
                semantic_l: 0.50,
                semantic_gain: 1.35,
                container_chroma: 0.35,
                text_chroma: 0.010,
                variant_text_chroma: 0.014,
            },
        }
    }
}

/// The finished palette, in DMS's role names.
pub struct Palette {
    pub roles: Vec<(&'static str, String)>,
}

/// Is this Oklch colour representable in sRGB?
///
/// NOTE THE UNCLAMPED CONVERSION. palette's `into_color()`/`FromColor` clamp the
/// result into the target type's valid range, so an out-of-gamut Oklch comes back
/// as a perfectly valid-looking LinSrgb and every gamut test passes. Using it here
/// silently made this function `true` for all inputs, which made `max_chroma_at`
/// return its search ceiling every time and left palette's own clipping -- the
/// exact thing this module exists to avoid -- doing all the work. Only
/// `into_color_unclamped()` tells the truth about the boundary.
fn in_gamut(c: Oklch) -> bool {
    let lin: LinSrgb = c.into_color_unclamped();
    const EPS: f32 = 1e-4;
    [lin.red, lin.green, lin.blue].iter().all(|&v| v >= -EPS && v <= 1.0 + EPS)
}

/// Largest chroma sRGB can carry at this lightness and hue.
///
/// Binary search rather than a closed form: the sRGB gamut boundary in OKLCH has
/// no clean analytic expression, and at 18 iterations this is exact to ~1e-6 and
/// still costs nothing (a few hundred of these run per palette).
fn max_chroma_at(l: f32, hue: f32) -> f32 {
    let mut lo = 0.0f32;
    let mut hi = 0.45f32;
    if in_gamut(Oklch::new(l, hi, hue)) {
        return hi;
    }
    for _ in 0..18 {
        let mid = 0.5 * (lo + hi);
        if in_gamut(Oklch::new(l, mid, hue)) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    lo
}

/// Resolve one role's colour, holding hue exactly.
///
/// This is where the salmon fix lives. Rather than accepting whatever chroma
/// survives at the Material tone, every lightness within `latitude` of the target
/// is scored on what chroma it can actually carry at this hue, minus a penalty
/// for straying:
///
///     utility(L) = min(gamut_ceiling(L), want) - pull * |L - target|
///
/// For a hue whose gamut ceiling is flat near the target -- most of them -- the
/// penalty wins and nothing moves. For red, whose ceiling collapses from 0.241 at
/// L=0.60 to 0.115 at L=0.80, the chroma on offer lower down is worth far more
/// than the lightness it costs, so the accent moves down and stays red.
///
/// `latitude` of zero opts out entirely and takes the clipped colour, which is
/// what Muted mode wants.
fn resolve(hue: f32, target_l: f32, want_c: f32, pull: f32, latitude: f32) -> Oklch {
    let ceiling_at = |l: f32| max_chroma_at(l, hue);
    if latitude <= 0.0 {
        return Oklch::new(target_l, want_c.min(ceiling_at(target_l)), hue);
    }

    let mut best_l = target_l;
    let mut best_u = want_c.min(ceiling_at(target_l));
    let steps = (latitude / 0.005).round() as i32;
    for i in 1..=steps {
        let d = i as f32 * 0.005;
        for cand in [target_l - d, target_l + d] {
            if !(0.05..=0.97).contains(&cand) {
                continue;
            }
            let u = want_c.min(ceiling_at(cand)) - pull * d;
            // Strictly greater, and the scan runs outward from the target, so a
            // tie always resolves to the lightness closest to where we asked.
            if u > best_u {
                best_u = u;
                best_l = cand;
            }
        }
    }
    Oklch::new(best_l, want_c.min(ceiling_at(best_l)), hue)
}

fn hex(c: Oklch) -> String {
    let rgb: Srgb = Srgb::from_color(c);
    let rgb8 = rgb.into_format::<u8>();
    format!("#{:02x}{:02x}{:02x}", rgb8.red, rgb8.green, rgb8.blue)
}

/// Readable ink for a given background: the palette's near-black or near-white,
/// whichever is further from it in lightness.
///
/// Compared rather than thresholded, because the accent's lightness is no longer
/// fixed -- the whole point of `resolve` is that it moves -- so a hardcoded
/// threshold would silently pick the wrong ink for exactly the hues this engine
/// exists to handle. Oklab L is perceptual, so the comparison means what it says.
fn ink_for(bg: Oklch, hue: f32) -> Oklch {
    const DARK_INK: f32 = 0.16;
    const LIGHT_INK: f32 = 0.98;
    if (bg.l - DARK_INK).abs() > (bg.l - LIGHT_INK).abs() {
        Oklch::new(DARK_INK, (0.020f32).min(max_chroma_at(DARK_INK, hue)), hue)
    } else {
        Oklch::new(LIGHT_INK, (0.014f32).min(max_chroma_at(LIGHT_INK, hue)), hue)
    }
}

/// Smallest signed angle from `a` to `b`, in degrees.
fn hue_delta(a: f32, b: f32) -> f32 {
    let d = ((b - a) % 360.0 + 540.0) % 360.0 - 180.0;
    d.abs()
}

/// Pick the cluster that should drive the accent.
///
/// Not simply the biggest: the biggest cluster on most wallpapers is the dark
/// background, and a palette accented in near-black is useless. But share must
/// not dominate either -- an earlier version scored share too heavily and picked
/// a 21.7% cluster at chroma 0.147 over a 15.9% one at 0.188 on the same
/// wallpaper. That single choice silently disabled the lightness fix downstream:
/// the duller seed asked for less chroma than the gamut could already supply at
/// the target tone, so nothing ever needed to move, and primary came out salmon.
///
/// So chroma leads, share only modulates, and clusters too small to be part of
/// what the wallpaper looks like are gated out entirely rather than scored.
fn pick_seed(clusters: &[Cluster]) -> Oklch {
    /// Below this share, a cluster is a speck rather than a colour of the image.
    const PRESENCE: f32 = 0.03;

    let max_share = clusters.iter().map(|c| c.share).fold(0.0f32, f32::max).max(1e-6);
    let mut best = Oklch::new(0.6, 0.1, 250.0);
    let mut best_score = f32::MIN;
    let mut gated = true;

    // Two passes: the gate is a filter, not a requirement. A wallpaper of many
    // tiny regions must still produce an accent.
    for pass in 0..2 {
        for c in clusters {
            if pass == 0 && c.share < PRESENCE {
                continue;
            }
            let lch = Oklch::from_color(c.color);
            // Peaks around L=0.55 and falls off toward black and white, where
            // there is no usable chroma to build an accent from anyway.
            let l_weight = 1.0 - ((lch.l - 0.55) / 0.55).powi(2).min(1.0);
            // Raw chroma, deliberately not saturating: for an *accent* the whole
            // question is which colour is most colourful, and a saturating curve
            // flattens exactly the distinction we are trying to make.
            let score = lch.chroma * l_weight * (0.5 + 0.5 * c.share / max_share);
            if score > best_score {
                best_score = score;
                best = lch;
                gated = false;
            }
        }
        if !gated {
            break;
        }
    }
    best
}

/// Hue for a supporting role: reuse a genuinely different colour from the
/// wallpaper when there is one, otherwise fall back to a fixed rotation. This is
/// what makes `--count` more than decoration -- more clusters means more chance
/// the secondary and tertiary come from the image instead of from arithmetic.
fn support_hue(clusters: &[Cluster], used: &[f32], fallback: f32, min_sep: f32) -> f32 {
    let mut best = None;
    let mut best_share = 0.0;
    for c in clusters {
        let lch = Oklch::from_color(c.color);
        if lch.chroma < 0.04 {
            continue;
        }
        if used.iter().any(|&u| hue_delta(u, lch.hue.into_positive_degrees()) < min_sep) {
            continue;
        }
        if c.share > best_share {
            best_share = c.share;
            best = Some(lch.hue.into_positive_degrees());
        }
    }
    best.unwrap_or(fallback)
}

pub fn build(clusters: &[Cluster], mode: Mode, scheme: Scheme) -> Palette {
    let p = mode.params();
    let t = scheme.targets();
    let seed = pick_seed(clusters);
    let h = seed.hue.into_positive_degrees();

    // Accent chroma target, from the wallpaper's own saturation rather than a
    // constant, so a washed-out wallpaper doesn't get a neon palette. Floored so
    // a nearly-grey wallpaper still produces a visible accent.
    //
    // SCHEME-INDEPENDENT ON PURPOSE. The hue and the amount of colour in the
    // wallpaper are properties of the wallpaper, not of whether the user is in
    // light mode -- so the two schemes are the same colour seen at different
    // lightnesses, which is the whole point of mirroring DMS's structure rather
    // than generating two unrelated palettes.
    let want = (seed.chroma * p.chroma_gain).clamp(0.055, 0.33);

    let h2 = support_hue(clusters, &[h], (h + 55.0) % 360.0, 25.0);
    let h3 = support_hue(clusters, &[h, h2], (h + 290.0) % 360.0, 25.0);

    // Containers get a quarter of the mode's latitude on purpose. They are the
    // other half of an accent pair, and the pair only works if the container
    // stays clearly separated from the accent -- letting a container chase the
    // cusp would collapse that contrast and, with it, every filled button in the
    // shell. In dark mode the container is the DARKER half; in light mode it is
    // the LIGHTER half. Same rule, opposite direction, and the targets above are
    // what encode the direction -- nothing here needs to know which scheme it is.
    let cl = p.l_latitude * 0.25;
    let cc = t.container_chroma;
    let primary = resolve(h, t.primary, want, p.chroma_pull, p.l_latitude);
    let primary_container = resolve(h, t.primary_container, want * 0.95 * cc, p.chroma_pull, cl);
    let secondary = resolve(h2, t.secondary, want * 0.62, p.chroma_pull, p.l_latitude);
    let secondary_container = resolve(h2, t.secondary_container, want * 0.55 * cc, p.chroma_pull, cl);
    let tertiary = resolve(h3, t.tertiary, want * 0.72, p.chroma_pull, p.l_latitude);
    let tertiary_container = resolve(h3, t.tertiary_container, want * 0.6 * cc, p.chroma_pull, cl);

    // Structural roles: hue kept for the tint, chroma kept tiny on purpose, and
    // lightness NOT allowed to move -- these are the tiers the whole UI's depth
    // cues rest on, so their ordering matters more than their colour. Holding the
    // hue here is what makes a light DankMango palette a tinted white (DMS's own
    // light surfaces are #fef7ff, #f7f9ff and so on) rather than a flat grey.
    let tint = |l: f32, c: f32| -> Oklch {
        let c = c * p.surface_chroma;
        Oklch::new(l, c.min(max_chroma_at(l, h)), h)
    };

    let surface = tint(t.surface, 0.008);
    let background = tint(t.background, 0.008);
    let surface_variant = tint(t.surface_variant, 0.014);
    let outline = tint(t.outline, 0.017);

    // Semantic roles are hue-fixed by meaning, not by wallpaper -- a green
    // "success" that follows a red wallpaper is a bug, not a feature. They still
    // go through the same machinery so they sit at the palette's lightness, and
    // they follow the scheme: DMS's own light `error` default is a dark, more
    // saturated red, not a pale one.
    let sem = |hue: f32, c: f32| resolve(hue, t.semantic_l, c * t.semantic_gain, 0.35, 0.18);

    let roles: Vec<(&'static str, String)> = vec![
        ("primary", hex(primary)),
        ("primaryText", hex(ink_for(primary, h))),
        ("primaryContainer", hex(primary_container)),
        ("secondary", hex(secondary)),
        ("secondaryContainer", hex(secondary_container)),
        ("tertiary", hex(tertiary)),
        ("tertiaryContainer", hex(tertiary_container)),
        ("surface", hex(surface)),
        ("surfaceText", hex(tint(t.surface_text, t.text_chroma))),
        ("surfaceVariant", hex(surface_variant)),
        ("surfaceVariantText", hex(tint(t.surface_variant_text, t.variant_text_chroma))),
        ("surfaceTint", hex(primary)),
        ("background", hex(background)),
        ("backgroundText", hex(tint(t.background_text, t.text_chroma))),
        ("outline", hex(outline)),
        ("surfaceContainerLowest", hex(tint(t.c_lowest, 0.006))),
        ("surfaceContainerLow", hex(tint(t.c_low, 0.008))),
        ("surfaceContainer", hex(tint(t.c_mid, 0.010))),
        ("surfaceContainerHigh", hex(tint(t.c_high, 0.012))),
        ("surfaceContainerHighest", hex(tint(t.c_highest, 0.014))),
        ("error", hex(sem(27.0, 0.16))),
        ("warning", hex(sem(75.0, 0.15))),
        ("info", hex(sem(245.0, 0.13))),
        ("success", hex(sem(150.0, 0.14))),
    ];

    Palette { roles }
}

/// Seed-colour entry point: same generation, no clustering.
pub fn seed_cluster(hexstr: &str) -> Result<Cluster, String> {
    let s = hexstr.trim().trim_start_matches('#');
    if s.len() != 6 || !s.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!("seed '{hexstr}' is not a 6-digit hex colour"));
    }
    let v = u32::from_str_radix(s, 16).map_err(|e| e.to_string())?;
    let srgb = Srgb::new(
        ((v >> 16) & 0xff) as u8,
        ((v >> 8) & 0xff) as u8,
        (v & 0xff) as u8,
    )
    .into_format::<f32>();
    let oklab: Oklab = srgb.into_linear().into_color();
    Ok(Cluster { color: oklab, share: 1.0 })
}
