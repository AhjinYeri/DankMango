//! Stage 1: pull the wallpaper's actual colours out of the image.
//!
//! k-means, run in Oklab rather than RGB. RGB distance is not perceptual --
//! two colours the same RGB distance apart can look nearly identical or wildly
//! different -- so clustering in RGB happily merges colours a human reads as
//! distinct and splits ones they read as the same. Oklab is (near enough)
//! perceptually uniform, so "close in the space" means "looks similar".
//!
//! The clustering itself is kmeans_colors'. That crate ships `Calculate` impls
//! for palette's `Lab` and `Rgb` only, so the Oklab point type below is ours;
//! its docs explicitly point at the `Lab` impl as the template for other
//! spaces, which is what this is. The algorithm is still theirs.

use kmeans_colors::{Calculate, Kmeans, get_kmeans};
use palette::{IntoColor, Oklab, Srgb};
use rand::Rng;

/// One extracted colour, with how much of the image it accounts for.
#[derive(Clone, Copy, Debug)]
pub struct Cluster {
    pub color: Oklab,
    /// Share of sampled pixels in this cluster, 0.0-1.0.
    pub share: f32,
}

/// Longest edge the image is scaled to before clustering.
///
/// k-means cost is linear in pixel count, and a palette does not get more
/// accurate from more samples of the same regions -- 256px keeps a 4K wallpaper
/// under a fifth of a second while still sampling every meaningful region.
const SAMPLE_MAX_EDGE: u32 = 256;

/// k-means is seeded randomly (k-means++), so a bad initial draw can land in a
/// poor local minimum. Three runs, keep the best-scoring, is the crate's own
/// recommended hedge and is cheap at this sample size.
const RUNS: u64 = 3;
const MAX_ITER: usize = 40;
/// Convergence threshold, in Oklab units. Oklab's L is 0-1 where CIE Lab's is
/// 0-100, so this is ~100x tighter-looking than the crate's Lab default of 5.0
/// and means about the same thing.
const CONVERGE: f32 = 0.0025;
/// Fixed seed: same wallpaper must give the same palette every run. A wallpaper
/// that recoloured itself slightly on every login would be worse than useless.
const SEED: u64 = 0x44616e6b4d616e67; // "DankMang"

/// An Oklab point for kmeans_colors. Plain f32 fields rather than a newtype
/// over `Oklab` so the arithmetic below stays readable.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct OkPoint {
    l: f32,
    a: f32,
    b: f32,
}

impl From<Oklab> for OkPoint {
    fn from(c: Oklab) -> Self {
        Self { l: c.l, a: c.a, b: c.b }
    }
}

impl From<OkPoint> for Oklab {
    fn from(p: OkPoint) -> Self {
        Oklab::new(p.l, p.a, p.b)
    }
}

impl Calculate for OkPoint {
    fn get_closest_centroid(buffer: &[Self], centroids: &[Self], indices: &mut Vec<u8>) {
        for color in buffer {
            let mut index = 0u8;
            let mut min = f32::MAX;
            for (idx, cent) in centroids.iter().enumerate() {
                let diff = Self::difference(color, cent);
                if diff < min {
                    min = diff;
                    index = idx as u8;
                }
            }
            indices.push(index);
        }
    }

    fn recalculate_centroids(
        rng: &mut impl Rng,
        buf: &[Self],
        centroids: &mut [Self],
        indices: &[u8],
    ) {
        for (idx, cent) in centroids.iter_mut().enumerate() {
            let (mut l, mut a, mut b) = (0.0f64, 0.0f64, 0.0f64);
            let mut count: u64 = 0;
            for (&jdx, p) in indices.iter().zip(buf) {
                if jdx as usize == idx {
                    l += p.l as f64;
                    a += p.a as f64;
                    b += p.b as f64;
                    count += 1;
                }
            }
            if count != 0 {
                let n = count as f64;
                *cent = OkPoint {
                    l: (l / n) as f32,
                    a: (a / n) as f32,
                    b: (b / n) as f32,
                };
            } else {
                // Empty cluster: the crate's contract is to re-seed it randomly.
                *cent = Self::create_random(rng);
            }
        }
    }

    fn check_loop(centroids: &[Self], old_centroids: &[Self]) -> f32 {
        let (mut l, mut a, mut b) = (0.0f32, 0.0, 0.0);
        for (c0, c1) in centroids.iter().zip(old_centroids) {
            l += c0.l - c1.l;
            a += c0.a - c1.a;
            b += c0.b - c1.b;
        }
        l * l + a * a + b * b
    }

    fn create_random(rng: &mut impl Rng) -> Self {
        // Oklab's real extents for sRGB: L in 0..1, a/b roughly +/-0.4.
        Self {
            l: rng.random_range(0.0..=1.0),
            a: rng.random_range(-0.4..=0.4),
            b: rng.random_range(-0.4..=0.4),
        }
    }

    fn difference(c1: &Self, c2: &Self) -> f32 {
        let (l, a, b) = (c1.l - c2.l, c1.a - c2.a, c1.b - c2.b);
        l * l + a * a + b * b
    }
}

/// Cluster a wallpaper into `count` colours, most-of-the-image first.
pub fn from_image(path: &str, count: usize) -> Result<Vec<Cluster>, String> {
    // SNIFFS THE CONTENT, does not trust the extension. image::open() picks its
    // decoder from the file name, so a PNG saved as "wallpaper.jpg" -- which is
    // extremely common, wallpaper sites and upscalers do it constantly -- fails
    // with "Illegal start bytes" instead of decoding fine. That failure is silent
    // in the automatic path (the wallpaper fan-out throws stderr away), so the
    // palette would just quietly stop following the wallpaper with nothing to
    // show why. with_guessed_format() reads the magic bytes and picks the real
    // decoder, so the name no longer has to be honest.
    let img = image::ImageReader::open(path)
        .map_err(|e| format!("cannot read image {path}: {e}"))?
        .with_guessed_format()
        .map_err(|e| format!("cannot read image {path}: {e}"))?
        .decode()
        .map_err(|e| format!("cannot decode image {path}: {e}"))?;
    // `thumbnail` box-filters on the way down, which averages rather than point-
    // samples -- point sampling would drop small saturated regions entirely.
    let small = img.thumbnail(SAMPLE_MAX_EDGE, SAMPLE_MAX_EDGE).to_rgba8();

    let mut points: Vec<OkPoint> = Vec::with_capacity(small.pixels().len());
    for px in small.pixels() {
        // Transparent pixels are not part of what the wallpaper looks like.
        if px.0[3] < 128 {
            continue;
        }
        let srgb = Srgb::new(px.0[0], px.0[1], px.0[2]).into_format::<f32>();
        let oklab: Oklab = srgb.into_linear().into_color();
        points.push(oklab.into());
    }
    if points.is_empty() {
        return Err(format!("{path} has no opaque pixels to sample"));
    }

    let k = count.min(points.len());
    let mut best = Kmeans::new();
    for run in 0..RUNS {
        let result = get_kmeans(k, MAX_ITER, CONVERGE, false, &points, SEED + run);
        if run == 0 || result.score < best.score {
            best = result;
        }
    }

    // kmeans_colors' Sort trait is also palette_color-only, and all we want from
    // it is the population share, which is a count over `indices`.
    let mut counts = vec![0usize; best.centroids.len()];
    for &i in &best.indices {
        counts[i as usize] += 1;
    }
    let total = best.indices.len() as f32;

    let mut clusters: Vec<Cluster> = best
        .centroids
        .iter()
        .zip(&counts)
        .map(|(&c, &n)| Cluster { color: c.into(), share: n as f32 / total })
        .collect();
    clusters.sort_by(|a, b| b.share.total_cmp(&a.share));
    Ok(clusters)
}
