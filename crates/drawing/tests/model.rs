//! SVG golden output, scene convergence, rasteriser and PNG checks.
//!
//! Re-bless the SVG golden only when the writer changes on purpose:
//! `DRAWING_BLESS=1 cargo test -p drawing --test model`.

use drawing::{InkPoint, RasterOptions, Scene, encode_png, pack, rasterize, sniff, to_svg};
use proto::{
    Actor, CoordSpace, DeviceId, DrawOp, Element, ElementId, ElementKind, ImageRef, MediaType,
    OpBatch, PrincipalId, Pt, ShapeKind, Stroke, Style, Tool, UnixMillis,
};

const ACTOR: Actor = Actor {
    principal: PrincipalId([1; 16]),
    device: DeviceId([2; 32]),
};

fn style(color: u32, width: f32) -> Style {
    Style { color, width }
}

fn stroke(id: u64, tool: Tool, points: &[(f32, f32, f32)]) -> Element {
    Element {
        id: ElementId(id),
        z: 0,
        style: style(0x2266_ddff, 4.0),
        kind: ElementKind::Stroke(Stroke {
            tool,
            points: pack(
                &points
                    .iter()
                    .enumerate()
                    .map(|(i, &(x, y, pressure))| InkPoint {
                        pressure,
                        ..InkPoint::at(x, y, i as u32 * 8)
                    })
                    .collect::<Vec<_>>(),
            ),
        }),
    }
}

fn sample() -> Scene {
    let mut scene = Scene::new();
    let ops = vec![
        DrawOp::Add(stroke(
            1,
            Tool::Pen,
            &[
                (10.0, 10.0, 0.5),
                (20.0, 14.0, 0.7),
                (30.0, 12.0, 0.9),
                (40.0, 20.0, 0.6),
            ],
        )),
        DrawOp::Add(Element {
            z: -1,
            ..stroke(2, Tool::Highlighter, &[(5.0, 30.0, 1.0), (60.0, 30.0, 1.0)])
        }),
        DrawOp::Add(Element {
            id: ElementId(3),
            z: 1,
            style: style(0xdd22_22ff, 2.0),
            kind: ElementKind::Shape {
                shape: ShapeKind::Arrow,
                from: Pt { x: 70.0, y: 60.0 },
                to: Pt { x: 45.0, y: 22.0 },
                filled: false,
            },
        }),
        DrawOp::Add(Element {
            id: ElementId(4),
            z: 1,
            style: style(0x0000_0080, 1.5),
            kind: ElementKind::Shape {
                shape: ShapeKind::Ellipse,
                from: Pt { x: 0.0, y: 0.0 },
                to: Pt { x: 50.0, y: 40.0 },
                filled: false,
            },
        }),
        DrawOp::Add(Element {
            id: ElementId(5),
            z: 2,
            style: style(0x1111_11ff, 1.0),
            kind: ElementKind::Text {
                at: Pt { x: 72.0, y: 62.0 },
                text: "fix <this>\n& that".into(),
                size: 12.0,
            },
        }),
        DrawOp::Add(Element {
            id: ElementId(6),
            z: 0,
            style: style(0x0000_00ff, 1.0),
            kind: ElementKind::Image {
                image: ImageRef {
                    hash: proto::BlobHash([7; 32]),
                    media: MediaType::Png,
                    size: 10,
                    width: 2,
                    height: 2,
                },
                from: Pt { x: 80.0, y: 0.0 },
                to: Pt { x: 100.0, y: 20.0 },
            },
        }),
        DrawOp::Add(Element {
            id: ElementId(7),
            z: 0,
            style: style(0x00aa_00ff, 2.0),
            kind: ElementKind::Shape {
                shape: ShapeKind::Rect,
                from: Pt { x: 90.0, y: 40.0 },
                to: Pt { x: 110.0, y: 55.0 },
                filled: true,
            },
        }),
    ];
    scene
        .apply(&OpBatch {
            version: 1,
            actor: ACTOR,
            at: UnixMillis(1),
            ops,
        })
        .unwrap();
    scene
}

#[test]
fn svg_matches_golden() {
    let scene = sample();
    let svg = to_svg(&scene, CoordSpace::Canvas, "a & b", &|image| {
        (image.hash.0[0] == 7).then(|| "data:image/png;base64,AAAA".to_owned())
    });
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/golden/sample.svg");
    if std::env::var_os("DRAWING_BLESS").is_some() {
        std::fs::create_dir_all(std::path::Path::new(path).parent().unwrap()).unwrap();
        std::fs::write(path, &svg).unwrap();
    }
    let golden = std::fs::read_to_string(path).expect("golden file (bless it once)");
    assert_eq!(svg, golden);
}

#[test]
fn cell_space_svg_scales_to_cells() {
    let mut scene = Scene::new();
    scene.apply_ops(&[DrawOp::Add(Element {
        style: style(0xff00_00ff, 0.2),
        ..stroke(1, Tool::Marker, &[(1.0, 0.5, 1.0), (11.0, 0.5, 1.0)])
    })]);
    let svg = to_svg(&scene, CoordSpace::Cells, "", &|_| None);
    // 10 columns of 9 units, 0.2 columns wide.
    assert!(svg.contains(r#"d="M9 9L99 9""#), "{svg}");
    assert!(svg.contains(r#"stroke-width="1.8""#), "{svg}");
}

#[test]
fn batches_converge_in_version_order_and_gaps_are_reported() {
    let batches: Vec<OpBatch> = vec![
        vec![DrawOp::Add(stroke(
            1,
            Tool::Pen,
            &[(0.0, 0.0, 1.0), (1.0, 1.0, 1.0)],
        ))],
        vec![DrawOp::Move {
            id: ElementId(1),
            dx: 5.0,
            dy: 0.0,
        }],
        vec![
            DrawOp::Add(stroke(2, Tool::Pen, &[(9.0, 9.0, 1.0)])),
            DrawOp::Delete { id: ElementId(1) },
        ],
        vec![DrawOp::SetTitle("t".into())],
    ]
    .into_iter()
    .enumerate()
    .map(|(i, ops)| OpBatch {
        version: i as u64 + 1,
        actor: ACTOR,
        at: UnixMillis(0),
        ops,
    })
    .collect();
    let mut in_order = Scene::new();
    let mut lagging = Scene::new();
    for batch in &batches {
        in_order.apply(batch).unwrap();
    }
    // Misses version 2 first, refuses 3, then catches up.
    lagging.apply(&batches[0]).unwrap();
    assert!(lagging.apply(&batches[2]).is_err());
    for batch in &batches[1..] {
        lagging.apply(batch).unwrap();
    }
    assert_eq!(in_order, lagging);
    assert_eq!(in_order.version, 4);
    assert_eq!(in_order.elements().len(), 1);
    assert_eq!(in_order.title.as_deref(), Some("t"));
    let rebuilt = Scene::from_elements(4, in_order.elements().to_vec());
    assert_eq!(rebuilt.elements(), in_order.elements());
}

#[test]
fn raster_and_png() {
    let scene = sample();
    let image = rasterize(&scene, CoordSpace::Canvas, RasterOptions::default());
    assert!(image.width > 200 && image.height > 100);
    // Some pixels are inked, the corner is background.
    assert_eq!(&image.data[..4], &[255, 255, 255, 255]);
    assert!(
        image
            .data
            .chunks(4)
            .any(|pixel| pixel[2] > 150 && pixel[0] < 100)
    );
    let png = encode_png(&image);
    assert_eq!(
        sniff(&png),
        Some((MediaType::Png, image.width, image.height))
    );
    let art = drawing::braille(&image, 40);
    assert!(art.lines().count() > 3);
    assert!(art.chars().any(|c| ('\u{2801}'..='\u{28ff}').contains(&c)));
    let small = rasterize(
        &scene,
        CoordSpace::Canvas,
        RasterOptions {
            max_side: 50,
            ..RasterOptions::default()
        },
    );
    assert!(small.width <= 50 && small.height <= 50);
}

#[test]
fn ink_encoding_sizes() {
    // A 1 s Pencil stroke sampled at 240 Hz (Pencil Pro rate), smooth curve.
    let points: Vec<InkPoint> = (0..240)
        .map(|i| {
            let t = i as f32 / 240.0;
            InkPoint {
                x: 100.0 + 300.0 * t,
                y: 200.0 + 40.0 * (t * 9.0).sin(),
                pressure: 0.4 + 0.3 * (t * 3.0).sin().abs(),
                altitude: 1.0 + 0.2 * t,
                azimuth: 2.0,
                t_ms: (i * 1000 / 240) as u32,
            }
        })
        .collect();
    let packed = pack(&points);
    let raw_f32 = points.len() * 6 * 4;
    let simplified = drawing::simplify(&points, 0.25);
    let packed_simple = pack(&simplified);
    let postcard_f32 = postcard_len(&points);
    println!(
        "{} points: f32×6 {} B, postcard f32 {} B, packed {} B ({:.1} B/pt); \
         simplified ε=0.25 → {} points, {} B",
        points.len(),
        raw_f32,
        postcard_f32,
        packed.0.len(),
        packed.0.len() as f32 / points.len() as f32,
        simplified.len(),
        packed_simple.0.len()
    );
    assert!(packed.0.len() < raw_f32 / 3);
    assert!(simplified.len() < points.len());
}

fn postcard_len(points: &[InkPoint]) -> usize {
    // postcard writes f32 as 4 bytes and u32 as a varint.
    points
        .iter()
        .map(|point| {
            5 * 4
                + if point.t_ms < 128 {
                    1
                } else if point.t_ms < 16384 {
                    2
                } else {
                    3
                }
        })
        .sum()
}
