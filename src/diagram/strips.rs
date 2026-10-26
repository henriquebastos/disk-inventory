//! Fixed-directory strip layout: rows span the long side and advance along the short side.
//! Candidate score (w/P * aspect)/(row_sum/P)^2 must remain at least 0.4.
//! Shared cumulative endpoints preserve proportions; zeros remain outside the diagram.
use crate::layout::{Rect, Tile};
pub(crate) fn place_strips(parts: &mut [Tile], rect: Rect, total: u64) -> bool {
    if !rect.valid()
        || total == 0
        || parts.iter().any(|p| p.bytes == 0)
        || parts.iter().map(|p| p.bytes).sum::<u64>() != total
    {
        return false;
    }
    parts.sort_by_key(|p| std::cmp::Reverse(p.bytes));
    let horizontal = rect.width >= rect.height;
    let long = rect.width.max(rect.height);
    let short = rect.width.min(rect.height);
    let ratio = long / short;
    let mut start = 0;
    let mut used = 0u64;
    while start < parts.len() {
        let mut end = start;
        let mut sum = 0u64;
        while end < parts.len() {
            let candidate = sum + parts[end].bytes;
            let fraction = candidate as f64 / total as f64;
            let score = (parts[end].bytes as f64 / total as f64 * ratio) / (fraction * fraction);
            if score < 0.4 {
                break;
            }
            sum = candidate;
            end += 1;
        }
        if end == start {
            return false;
        }
        let near = short * (used as f64 / total as f64);
        used += sum;
        let far = if used == total {
            short
        } else {
            short * (used as f64 / total as f64)
        };
        let mut across = 0u64;
        for tile in &mut parts[start..end] {
            let left = long * (across as f64 / sum as f64);
            across += tile.bytes;
            let right = if across == sum {
                long
            } else {
                long * (across as f64 / sum as f64)
            };
            tile.rect = if horizontal {
                Rect {
                    x: rect.x + left,
                    y: rect.y + near,
                    width: (rect.x + right) - (rect.x + left),
                    height: (rect.y + far) - (rect.y + near),
                }
            } else {
                Rect {
                    x: rect.x + near,
                    y: rect.y + left,
                    width: (rect.x + far) - (rect.x + near),
                    height: (rect.y + right) - (rect.y + left),
                }
            };
            let expected = rect.area() * (tile.bytes as f64 / total as f64);
            if !rect.contains(tile.rect) || (tile.rect.area() - expected).abs() > expected * 1e-9 {
                return false;
            }
        }
        start = end;
    }
    true
}
