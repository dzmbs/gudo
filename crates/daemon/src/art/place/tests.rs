use super::size_for;
use proto::{BlobHash, ImageRef, MediaType, PaneSize};

fn image(width: u32, height: u32) -> ImageRef {
    ImageRef {
        hash: BlobHash([0; 32]),
        media: MediaType::Png,
        size: 0,
        width,
        height,
    }
}

const PANE: PaneSize = PaneSize {
    cols: 120,
    rows: 36,
    width_px: 0,
    height_px: 0,
};

#[test]
fn automatic_placements_fit_a_third_of_the_pane_without_upscaling_small_images() {
    for image in [image(4000, 4000), image(4000, 500), image(500, 4000)] {
        let (cols, rows) = size_for(&image, PANE, 0, 0, 0);
        assert!((1..=40).contains(&cols), "columns: {cols}");
        assert!((1..=12).contains(&rows), "rows: {rows}");
    }
    assert_eq!(size_for(&image(18, 36), PANE, 0, 0, 0), (1, 1));
    assert_eq!(size_for(&image(4000, 4000), PANE, 0, 0, 0), (24, 12));
    assert_eq!(size_for(&image(500, 4000), PANE, 0, 0, 0), (3, 12));
    let square_cells = PaneSize {
        width_px: 2400,
        height_px: 720,
        ..PANE
    };
    assert_eq!(
        size_for(&image(4000, 4000), square_cells, 0, 0, 0),
        (12, 12)
    );
}

#[test]
fn explicit_drawing_geometry_is_not_capped_and_cursor_room_is_respected() {
    assert_eq!(size_for(&image(4000, 4000), PANE, 0, 80, 20), (80, 20));
    let (cols, rows) = size_for(&image(4000, 4000), PANE, 115, 0, 0);
    assert!((1..=5).contains(&cols));
    assert!((1..=12).contains(&rows));
}
