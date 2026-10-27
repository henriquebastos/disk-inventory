//! Bounded presentation transfers; opaque views never authorize filesystem operations.
use super::*;
use crate::{diagram::Diagram, tree_view::TreeView};
#[derive(uniffi::Record)]
pub struct OutlineRow {
    pub entry: EntryRecord,
    /// `0xRRGGBB` base color of this entry's map file tile; `None` for directories.
    pub map_rgb: Option<u32>,
    pub depth: u32,
    pub expanded: bool,
}
#[derive(uniffi::Record)]
pub struct OutlineSlice {
    pub offset: u64,
    pub total: u64,
    pub rows: Vec<OutlineRow>,
    pub visits: u64,
    pub expanded_directories: u64,
    pub expansion_payload_bytes: u64,
}
#[derive(uniffi::Record)]
pub struct BitmapRecord {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    pub tiles: u64,
    pub groups: u64,
    pub child_visits: u64,
    pub retained_payload_bytes: u64,
    pub surface_payload_bytes: u64,
    pub aggregate_pixels: u64,
    pub layout_micros: u64,
    pub raster_micros: u64,
}
#[derive(uniffi::Record)]
pub struct DiagramSelection {
    pub entry: EntryRecord,
    pub relative_path: Vec<u8>,
    pub actionable: bool,
    pub rect: Rectangle,
    pub bytes: u64,
}
#[derive(uniffi::Object)]
pub struct ExplorerTree {
    session: Arc<ExplorerSession>,
    revision: u64,
    state: Mutex<TreeView>,
}
#[derive(uniffi::Object)]
pub struct DiagramFrame {
    session: Arc<ExplorerSession>,
    revision: u64,
    diagram: Diagram,
}
fn stale() -> BridgeError {
    BridgeError::InvalidInput {
        message: "presentation belongs to an obsolete inventory revision".into(),
    }
}
#[uniffi::export]
impl ExplorerSession {
    pub fn tree(self: Arc<Self>, root: Arc<EntryKey>) -> Result<Arc<ExplorerTree>, BridgeError> {
        self.with(|b| {
            Ok(Arc::new(ExplorerTree {
                session: self.clone(),
                revision: self.revision.load(Ordering::Acquire),
                state: Mutex::new(TreeView::new(b.explorer(), b.validate(&root)?)?),
            }))
        })
    }
    pub fn diagram(
        self: Arc<Self>,
        focus: Arc<EntryKey>,
        width: u32,
        height: u32,
    ) -> Result<Arc<DiagramFrame>, BridgeError> {
        self.with(|b| {
            Ok(Arc::new(DiagramFrame {
                session: self.clone(),
                revision: self.revision.load(Ordering::Acquire),
                diagram: b.explorer().diagram(b.validate(&focus)?, width, height)?,
            }))
        })
    }
}
impl ExplorerTree {
    fn with<T>(
        &self,
        f: impl FnOnce(&Explorer, &mut TreeView) -> Result<T, BridgeError>,
    ) -> Result<T, BridgeError> {
        self.session.with(|b| {
            if self.revision != self.session.revision.load(Ordering::Acquire) {
                return Err(stale());
            }
            f(b.explorer(), &mut *lock(&self.state)?)
        })
    }
}
#[uniffi::export]
impl ExplorerTree {
    pub fn rows(&self, offset: u64, limit: u32) -> Result<OutlineSlice, BridgeError> {
        self.with(|e, t| {
            let offset = usize::try_from(offset).map_err(|_| stale())?;
            let p = t.rows(e, offset, limit as usize)?;
            Ok(OutlineSlice {
                offset: offset as u64,
                total: p.total as u64,
                rows: p
                    .rows
                    .into_iter()
                    .map(|r| OutlineRow {
                        map_rgb: (r.entry.kind != crate::Kind::Dir).then(|| {
                            let [red, green, blue] = crate::diagram::type_color(r.entry.basename);
                            u32::from_be_bytes([0, red, green, blue])
                        }),
                        entry: r.entry.into(),
                        depth: r.depth,
                        expanded: r.expanded,
                    })
                    .collect(),
                visits: p.visits as u64,
                expanded_directories: t.expanded_count() as u64,
                expansion_payload_bytes: t.expansion_payload_bytes() as u64,
            })
        })
    }
    pub fn expand(&self, key: Arc<EntryKey>, expanded: bool) -> Result<u64, BridgeError> {
        self.with(|e, t| {
            t.expand(e, key.handle, expanded)?;
            Ok(t.row_count() as u64)
        })
    }
    pub fn visible_row(&self, key: Arc<EntryKey>) -> Result<Option<u64>, BridgeError> {
        self.with(|e, t| Ok(t.visible_row(e, key.handle)?.map(|row| row as u64)))
    }
    pub fn reveal(&self, key: Arc<EntryKey>) -> Result<u64, BridgeError> {
        self.with(|e, t| Ok(t.reveal(e, key.handle)? as u64))
    }
}
#[uniffi::export]
impl DiagramFrame {
    pub fn bitmap(&self) -> BitmapRecord {
        let d = &self.diagram;
        let s = d.stats;
        BitmapRecord {
            width: d.width,
            height: d.height,
            rgba: d.rgba().to_vec(),
            tiles: s.tiles as u64,
            groups: s.groups as u64,
            child_visits: s.child_visits as u64,
            retained_payload_bytes: s.retained_payload_bytes as u64,
            surface_payload_bytes: s.surface_payload_bytes as u64,
            aggregate_pixels: s.aggregate_pixels as u64,
            layout_micros: s.layout_micros,
            raster_micros: s.raster_micros,
        }
    }
    pub fn hit(&self, x: u32, y: u32) -> Result<Option<DiagramSelection>, BridgeError> {
        self.session.with(|b| {
            if self.revision != self.session.revision.load(Ordering::Acquire) {
                return Err(stale());
            }
            self.diagram
                .hit(x, y)
                .map(|h| {
                    Ok(DiagramSelection {
                        entry: b.explorer().entry(h.key)?.into(),
                        relative_path: b.explorer().relative_path(h.key)?,
                        actionable: h.actionable,
                        rect: h.rect.into(),
                        bytes: h.bytes,
                    })
                })
                .transpose()
        })
    }
    /// A bounded accessibility alternative for large file tiles; the tree exposes every entry.
    pub fn targets(&self) -> Result<Vec<DiagramSelection>, BridgeError> {
        self.session.with(|b| {
            if self.revision != self.session.revision.load(Ordering::Acquire) {
                return Err(stale());
            }
            let mut result = vec![];
            for tile in &self.diagram.layout.tiles {
                if result.len() == 24 {
                    break;
                }
                if tile.rect.width < 8.0 || tile.rect.height < 8.0 {
                    continue;
                }
                if let Some(h) = self.diagram.hit(
                    (tile.rect.x + tile.rect.width / 2.0) as u32,
                    (tile.rect.y + tile.rect.height / 2.0) as u32,
                ) && h.actionable
                {
                    result.push(DiagramSelection {
                        entry: b.explorer().entry(h.key)?.into(),
                        relative_path: b.explorer().relative_path(h.key)?,
                        actionable: true,
                        rect: h.rect.into(),
                        bytes: h.bytes,
                    });
                }
            }
            Ok(result)
        })
    }
    pub fn region(&self, key: Arc<EntryKey>) -> Result<Option<Rectangle>, BridgeError> {
        self.session.with(|b| {
            if self.revision != self.session.revision.load(Ordering::Acquire) {
                return Err(stale());
            }
            b.validate(&key)?;
            Ok(self.diagram.region(key.handle).map(Into::into))
        })
    }
}
