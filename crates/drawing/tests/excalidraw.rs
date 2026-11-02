//! Excalidraw scenes: reconciliation, `.excalidraw` parsing, and the ASCII golden.
//!
//! Re-bless the ASCII golden only on purpose: `DRAWING_BLESS=1 cargo test -p drawing --test
//! excalidraw`.

use drawing::{ExScene, parse_element, parse_file, to_ascii, to_svg};
use proto::{CoordSpace, ExElement};

const FLOW: &[u8] = include_bytes!("fixtures/flow.excalidraw");

fn element(id: &str, version: u64, nonce: u32) -> ExElement {
    ExElement {
        id: id.into(),
        version,
        version_nonce: nonce,
        deleted: false,
        json: format!(r#"{{"id":"{id}","version":{version},"versionNonce":{nonce}}}"#),
    }
}

#[test]
fn reconciliation_matches_excalidraw() {
    let mut scene = ExScene::new();
    let (won, lost) = scene.merge(vec![element("a", 1, 50), element("b", 1, 5)]);
    assert_eq!((won.len(), lost.len(), scene.revision), (2, 0, 1));
    // Higher version wins; a tie goes to the lower nonce; a lower version loses.
    let (won, lost) = scene.merge(vec![element("a", 2, 99), element("b", 1, 9)]);
    assert_eq!(won, vec![element("a", 2, 99)]);
    assert_eq!(lost, vec![element("b", 1, 5)]);
    let (won, _) = scene.merge(vec![element("b", 1, 1)]);
    assert_eq!(won, vec![element("b", 1, 1)]);
    let (won, lost) = scene.merge(vec![element("a", 1, 0)]);
    assert!(won.is_empty());
    assert_eq!(lost, vec![element("a", 2, 99)]);
    assert_eq!(scene.revision, 3);
    assert_eq!(scene.changed_since(2), vec![element("b", 1, 1)]);
    // Two replicas that see the same offers in any order converge.
    let offers = vec![
        element("x", 3, 7),
        element("x", 3, 2),
        element("x", 2, 0),
        element("y", 1, 1),
    ];
    let mut forward = ExScene::new();
    let mut backward = ExScene::new();
    for offer in &offers {
        forward.merge(vec![offer.clone()]);
    }
    for offer in offers.iter().rev() {
        backward.merge(vec![offer.clone()]);
    }
    assert_eq!(forward.changed_since(0), backward.changed_since(0));
    let parsed =
        parse_element(r#"{"id":"q","version":4,"versionNonce":12,"isDeleted":true}"#).unwrap();
    assert_eq!(
        (
            parsed.id.as_str(),
            parsed.version,
            parsed.version_nonce,
            parsed.deleted
        ),
        ("q", 4, 12, true)
    );
    assert!(parse_element(r#"{"version":1}"#).is_err());
}

#[test]
fn excalidraw_file_exports_to_ascii_and_svg() {
    let file = parse_file(FLOW).unwrap();
    assert_eq!(file.elements.len(), 9);
    assert!(file.app_state.unwrap().contains("gridSize"));
    let mut excalidraw = ExScene::new();
    excalidraw.merge(file.elements);
    assert_eq!(excalidraw.live(), 8);
    let scene = excalidraw.to_scene();
    let ascii = to_ascii(&scene, CoordSpace::Canvas, 100);
    println!("{ascii}");
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/golden/flow.txt");
    if std::env::var_os("DRAWING_BLESS").is_some() {
        std::fs::write(path, &ascii).unwrap();
    }
    assert_eq!(
        ascii,
        std::fs::read_to_string(path).expect("golden (bless it once)")
    );
    for word in ["client", "daemon", "agent", "▶", "▼", "┌", "╭"] {
        assert!(ascii.contains(word), "{word} missing:\n{ascii}");
    }
    let svg = to_svg(&scene, CoordSpace::Canvas, "flow", &|_| None);
    assert!(svg.contains("<ellipse") && svg.contains(">daemon<") && svg.contains("#a5d8ff"));
    assert!(!parse_file(br#"{"type":"other"}"#).is_ok());
}

#[test]
fn excalidraw_file_round_trips_without_tombstones() {
    let mut file = parse_file(FLOW).unwrap();
    file.files.push((
        "img1".into(),
        "image/png".into(),
        vec![0x89, b'P', b'N', b'G'],
    ));
    let back = parse_file(file.to_json().as_bytes()).unwrap();
    assert_eq!(back.elements.len(), 8, "the deleted element is left out");
    assert!(back.elements.iter().all(|element| !element.deleted));
    let ids = |file: &drawing::ExcalidrawFile| {
        file.elements
            .iter()
            .filter(|element| !element.deleted)
            .map(|element| (element.id.clone(), element.version))
            .collect::<Vec<_>>()
    };
    assert_eq!(
        ids(&back),
        ids(&file),
        "elements keep their order and versions"
    );
    assert!(back.app_state.unwrap().contains("gridSize"));
    assert_eq!(
        back.files,
        vec![(
            "img1".into(),
            "image/png".into(),
            vec![0x89, b'P', b'N', b'G']
        )]
    );
}
