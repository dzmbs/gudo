//! Excalidraw scenes: per-element reconciliation, `.excalidraw` files, and conversion to a
//! [`Scene`] for SVG, PNG and ASCII export.
//!
//! Elements stay Excalidraw's own JSON ([`ExElement::json`]); only `id`, `version`,
//! `versionNonce` and `isDeleted` are read to reconcile, exactly as Excalidraw's collaboration
//! does (`reconcileElements`): the higher `version` wins, a tie goes to the lower
//! `versionNonce`. Deletions are tombstones (`isDeleted: true`), so they reconcile too.

use std::collections::BTreeMap;

use proto::{
    DrawOp, Element, ElementId, ElementKind, ExElement, ExFile, ImageRef, Pt, ShapeKind, Stroke,
    Style, Tool,
};
use serde_json::Value;

use crate::points::{InkPoint, pack};
use crate::scene::Scene;

/// Whether `incoming` replaces `current` (Excalidraw's rule).
pub fn wins(incoming: &ExElement, current: &ExElement) -> bool {
    incoming.version > current.version
        || (incoming.version == current.version && incoming.version_nonce < current.version_nonce)
}

/// Reads the reconciliation fields of an element's JSON.
///
/// # Errors
///
/// A message when the JSON is not an object with a string `id` and a numeric `version`.
pub fn parse_element(json: &str) -> Result<ExElement, String> {
    let value: Value = serde_json::from_str(json).map_err(|error| error.to_string())?;
    element_from_value(&value, json.to_owned())
}

fn element_from_value(value: &Value, json: String) -> Result<ExElement, String> {
    let id = value["id"]
        .as_str()
        .ok_or("element without an id")?
        .to_owned();
    let version = value["version"]
        .as_u64()
        .ok_or("element without a version")?;
    Ok(ExElement {
        id,
        version,
        version_nonce: value["versionNonce"].as_u64().unwrap_or(0) as u32,
        deleted: value["isDeleted"].as_bool().unwrap_or(false),
        json,
    })
}

/// A scene: elements by id with the revision each last changed at, app state and files.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ExScene {
    /// Bumped by every merge that changed something.
    pub revision: u64,
    elements: BTreeMap<String, (ExElement, u64)>,
    /// The persistent app state JSON.
    pub app_state: Option<String>,
    /// Files by Excalidraw file id.
    pub files: BTreeMap<String, ExFile>,
}

impl ExScene {
    pub fn new() -> Self {
        Self::default()
    }

    /// Merges `incoming`; returns the elements that won (now stored, at the new revision)
    /// and, for those that lost, the stored winners. The revision is bumped once if anything
    /// won.
    pub fn merge(&mut self, incoming: Vec<ExElement>) -> (Vec<ExElement>, Vec<ExElement>) {
        let next = self.revision + 1;
        let (mut won, mut lost) = (Vec::new(), Vec::new());
        for element in incoming {
            match self.elements.get(&element.id) {
                Some((current, _)) if !wins(&element, current) => {
                    if current != &element {
                        lost.push(current.clone());
                    }
                }
                _ => {
                    self.elements
                        .insert(element.id.clone(), (element.clone(), next));
                    won.push(element);
                }
            }
        }
        if !won.is_empty() {
            self.revision = next;
        }
        (won, lost)
    }

    /// Applies elements someone else won with, at `revision` (a client's cache).
    pub fn absorb(&mut self, elements: Vec<ExElement>, revision: u64) {
        for element in elements {
            let keep = self
                .elements
                .get(&element.id)
                .is_some_and(|(current, _)| !wins(&element, current));
            if !keep {
                self.elements
                    .insert(element.id.clone(), (element, revision));
            }
        }
        self.revision = self.revision.max(revision);
    }

    /// Elements changed after `since` (all, tombstones included, for 0).
    pub fn changed_since(&self, since: u64) -> Vec<ExElement> {
        self.elements
            .values()
            .filter(|(_, revision)| *revision > since)
            .map(|(element, _)| element.clone())
            .collect()
    }

    /// Every element with the revision it last changed at.
    pub fn with_revisions(&self) -> impl Iterator<Item = (&ExElement, u64)> {
        self.elements
            .values()
            .map(|(element, revision)| (element, *revision))
    }

    /// Restores an element with its revision (loading from disk).
    pub fn restore(&mut self, element: ExElement, revision: u64) {
        self.revision = self.revision.max(revision);
        self.elements
            .insert(element.id.clone(), (element, revision));
    }

    /// Number of live (not deleted) elements.
    pub fn live(&self) -> usize {
        self.elements
            .values()
            .filter(|(element, _)| !element.deleted)
            .count()
    }

    /// Bytes of element JSON held.
    pub fn bytes(&self) -> usize {
        self.elements
            .values()
            .map(|(element, _)| element.json.len())
            .sum::<usize>()
            + self.app_state.as_ref().map_or(0, String::len)
    }

    /// The scene as vector elements (for SVG, PNG and ASCII). Hand-drawn roughness is not
    /// reproduced; the app's Excalidraw renders the real look and can upload it as a preview.
    pub fn to_scene(&self) -> Scene {
        let mut ops = Vec::new();
        let mut next = 1u64;
        for (element, _) in self.elements.values() {
            if element.deleted {
                continue;
            }
            if let Ok(value) = serde_json::from_str::<Value>(&element.json) {
                convert(&value, &self.files, &mut next, &mut ops);
            }
        }
        // Excalidraw draws in array order, which is its `index` (fractional) order.
        let mut scene = Scene::new();
        scene.apply_ops(&ops);
        scene.version = self.revision;
        scene
    }
}

fn color(css: &str, opacity: f64) -> Option<u32> {
    let hex = css.strip_prefix('#')?;
    let rgb = match hex.len() {
        6 => u32::from_str_radix(hex, 16).ok()?,
        3 => {
            let short = u32::from_str_radix(hex, 16).ok()?;
            let (r, g, b) = ((short >> 8) & 0xf, (short >> 4) & 0xf, short & 0xf);
            (r * 17) << 16 | (g * 17) << 8 | (b * 17)
        }
        _ => return None,
    };
    let alpha = (opacity.clamp(0.0, 100.0) / 100.0 * 255.0).round() as u32;
    Some(rgb << 8 | alpha)
}

fn num(value: &Value) -> f32 {
    value.as_f64().unwrap_or(0.0) as f32
}

fn convert(
    element: &Value,
    files: &BTreeMap<String, ExFile>,
    next: &mut u64,
    ops: &mut Vec<DrawOp>,
) {
    let (x, y, w, h) = (
        num(&element["x"]),
        num(&element["y"]),
        num(&element["width"]),
        num(&element["height"]),
    );
    let opacity = element["opacity"].as_f64().unwrap_or(100.0);
    let stroke = color(
        element["strokeColor"].as_str().unwrap_or("#1e1e1e"),
        opacity,
    )
    .unwrap_or(0x1e1e_1eff);
    let fill = element["backgroundColor"]
        .as_str()
        .and_then(|css| color(css, opacity));
    let width = element["strokeWidth"].as_f64().unwrap_or(2.0) as f32;
    let mut push = |kind: ElementKind, color: u32, width: f32| {
        ops.push(DrawOp::Add(Element {
            id: ElementId(*next),
            z: 0,
            style: Style { color, width },
            kind,
        }));
        *next += 1;
    };
    let p = |px: f32, py: f32| Pt { x: px, y: py };
    let shape = |shape: ShapeKind, filled: bool| ElementKind::Shape {
        shape,
        from: p(x, y),
        to: p(x + w, y + h),
        filled,
    };
    // Excalidraw points are relative to the element's x/y.
    let points: Vec<(f32, f32)> = element["points"]
        .as_array()
        .map(|array| {
            array
                .iter()
                .map(|point| (x + num(&point[0]), y + num(&point[1])))
                .collect()
        })
        .unwrap_or_default();
    match element["type"].as_str().unwrap_or("") {
        kind @ ("rectangle" | "ellipse" | "frame" | "embeddable" | "iframe") => {
            let outline = if kind == "ellipse" {
                ShapeKind::Ellipse
            } else {
                ShapeKind::Rect
            };
            if let Some(fill) = fill {
                push(shape(outline, true), fill, 0.0);
            }
            push(shape(outline, false), stroke, width);
        }
        "diamond" => {
            let (cx, cy) = (x + w / 2.0, y + h / 2.0);
            let corners = [p(cx, y), p(x + w, cy), p(cx, y + h), p(x, cy), p(cx, y)];
            for seg in corners.windows(2) {
                push(
                    ElementKind::Shape {
                        shape: ShapeKind::Line,
                        from: seg[0],
                        to: seg[1],
                        filled: false,
                    },
                    stroke,
                    width,
                );
            }
        }
        kind @ ("arrow" | "line") => {
            let end_head = kind == "arrow" && !element["endArrowhead"].is_null();
            let start_head = !element["startArrowhead"].is_null() && kind == "arrow";
            for (i, seg) in points.windows(2).enumerate() {
                let (mut a, mut b) = (p(seg[0].0, seg[0].1), p(seg[1].0, seg[1].1));
                let mut shape = ShapeKind::Line;
                if i + 2 == points.len() && end_head {
                    shape = ShapeKind::Arrow;
                } else if i == 0 && start_head {
                    std::mem::swap(&mut a, &mut b);
                    shape = ShapeKind::Arrow;
                }
                push(
                    ElementKind::Shape {
                        shape,
                        from: a,
                        to: b,
                        filled: false,
                    },
                    stroke,
                    width,
                );
            }
        }
        "freedraw" => {
            let pressures: Vec<f32> = element["pressures"]
                .as_array()
                .map(|array| array.iter().map(num).collect())
                .unwrap_or_default();
            let ink: Vec<InkPoint> = points
                .iter()
                .enumerate()
                .map(|(i, &(px, py))| InkPoint {
                    pressure: pressures
                        .get(i)
                        .copied()
                        .filter(|pressure| *pressure > 0.0)
                        .unwrap_or(0.6),
                    ..InkPoint::at(px, py, i as u32 * 8)
                })
                .collect();
            push(
                ElementKind::Stroke(Stroke {
                    tool: Tool::Pen,
                    points: pack(&ink),
                }),
                stroke,
                width * 1.5,
            );
        }
        "text" => {
            let text = element["text"].as_str().unwrap_or_default().to_owned();
            push(
                ElementKind::Text {
                    at: p(x, y),
                    text,
                    size: element["fontSize"].as_f64().unwrap_or(20.0) as f32,
                },
                stroke,
                1.0,
            );
        }
        "image" => {
            let image: Option<ImageRef> = element["fileId"]
                .as_str()
                .and_then(|file_id| files.get(file_id))
                .map(|file| file.image);
            if let Some(image) = image {
                push(
                    ElementKind::Image {
                        image,
                        from: p(x, y),
                        to: p(x + w, y + h),
                    },
                    0xff,
                    0.0,
                );
            } else {
                push(shape(ShapeKind::Rect, false), stroke, 1.0);
            }
        }
        _ => {}
    }
}

/// A parsed `.excalidraw` file: elements, app state, and the images it embeds (file id,
/// MIME type, decoded bytes).
#[derive(Debug, Clone, Default)]
pub struct ExcalidrawFile {
    pub elements: Vec<ExElement>,
    /// `appState` as JSON.
    pub app_state: Option<String>,
    /// Embedded images.
    pub files: Vec<(String, String, Vec<u8>)>,
}

/// Parses an `.excalidraw` file (`{"type":"excalidraw","version":2,"elements":[…],
/// "appState":{…},"files":{id:{mimeType,dataURL}}}`).
///
/// # Errors
///
/// A message when it is not such a file.
pub fn parse_file(bytes: &[u8]) -> Result<ExcalidrawFile, String> {
    let root: Value = serde_json::from_slice(bytes).map_err(|error| error.to_string())?;
    if root["type"].as_str() != Some("excalidraw") {
        return Err("not an Excalidraw file".into());
    }
    let mut out = ExcalidrawFile::default();
    for element in root["elements"].as_array().ok_or("no elements")? {
        out.elements
            .push(element_from_value(element, element.to_string())?);
    }
    if root["appState"].is_object() {
        out.app_state = Some(root["appState"].to_string());
    }
    if let Some(files) = root["files"].as_object() {
        for (id, file) in files {
            let mime = file["mimeType"].as_str().unwrap_or_default().to_owned();
            let Some(data) = file["dataURL"]
                .as_str()
                .and_then(|url| url.split_once(";base64,"))
                .and_then(|(_, base64)| data_encoding::BASE64.decode(base64.as_bytes()).ok())
            else {
                continue;
            };
            out.files.push((id.clone(), mime, data));
        }
    }
    Ok(out)
}

impl ExcalidrawFile {
    /// A scene holding one image (`bytes`, a `width` × `height` px PNG or JPEG) at the
    /// origin, at half its pixel size (our renders are 2×).
    ///
    /// # Examples
    ///
    /// ```
    /// let file = drawing::ExcalidrawFile::from_image("ab12", "image/png", vec![1, 2], 400, 200);
    /// assert_eq!(file.elements.len(), 1);
    /// assert!(file.elements[0].json.contains(r#""width":200.0"#));
    /// ```
    pub fn from_image(file_id: &str, mime: &str, bytes: Vec<u8>, width: u32, height: u32) -> Self {
        let json = serde_json::json!({
            "type": "image", "id": format!("image-{file_id:.12}"), "fileId": file_id,
            "x": 0, "y": 0, "width": f64::from(width) / 2.0, "height": f64::from(height) / 2.0,
            "angle": 0, "strokeColor": "transparent", "backgroundColor": "transparent",
            "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
            "opacity": 100, "groupIds": [], "frameId": null, "roundness": null, "seed": 1,
            "version": 1, "versionNonce": 1, "isDeleted": false, "boundElements": null,
            "updated": 1, "link": null, "locked": false, "status": "saved", "scale": [1, 1],
        });
        let element = element_from_value(&json, json.to_string())
            .expect("the element has an id and a version");
        Self {
            elements: vec![element],
            app_state: None,
            files: vec![(file_id.to_owned(), mime.to_owned(), bytes)],
        }
    }

    /// Writes the scene as an `.excalidraw` file, the form [`parse_file`] reads and Excalidraw
    /// opens: live elements in order, the app state, and every image as a `data:` URL.
    /// Deleted elements (tombstones) are left out.
    ///
    /// # Examples
    ///
    /// ```
    /// let file = drawing::ExcalidrawFile {
    ///     elements: vec![drawing::parse_element(r#"{"id":"a","version":1}"#).unwrap()],
    ///     app_state: None,
    ///     files: vec![],
    /// };
    /// let back = drawing::parse_file(file.to_json().as_bytes()).unwrap();
    /// assert_eq!(back.elements[0].id, "a");
    /// ```
    pub fn to_json(&self) -> String {
        let elements: Vec<Value> = self
            .elements
            .iter()
            .filter(|element| !element.deleted)
            .filter_map(|element| serde_json::from_str(&element.json).ok())
            .collect();
        let app_state = self
            .app_state
            .as_deref()
            .and_then(|json| serde_json::from_str::<Value>(json).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| serde_json::json!({}));
        let files: serde_json::Map<String, Value> = self
            .files
            .iter()
            .map(|(id, mime, bytes)| {
                let url = format!("data:{mime};base64,{}", data_encoding::BASE64.encode(bytes));
                let file = serde_json::json!({ "id": id, "mimeType": mime, "dataURL": url });
                (id.clone(), file)
            })
            .collect();
        serde_json::json!({
            "type": "excalidraw",
            "version": 2,
            "elements": elements,
            "appState": app_state,
            "files": files,
        })
        .to_string()
    }
}
