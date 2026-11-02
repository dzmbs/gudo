//! Kitty graphics through Ghostty: the daemon's VT keeps the images, clients mirror them from
//! the byte stream, query replies reach the program, and snapshots carry images (pixels
//! included) to a client that attaches later.

use std::path::Path;

use client_core::ClientConfig;
use client_core::drawing;
use client_core::proto::PaneId;
use ghostty_vt::{KittyImage, KittyPlacement};

use crate::support::{TestClient, start, ticket};

/// An APC with kitty graphics `params` and base64 `payload`.
fn apc(params: &str, payload: &[u8]) -> String {
    format!(
        "\x1b_G{params};{}\x1b\\",
        data_encoding::BASE64.encode(payload)
    )
}

fn png(width: u32, height: u32, shade: u8) -> Vec<u8> {
    drawing::encode_png(&drawing::Rgba {
        width,
        height,
        data: vec![shade; (width * height * 4) as usize],
    })
}

/// Writes `bytes` to a file and has the pane's shell `cat` it, then print `done` (the shell
/// computes part of it, so the echoed command line never matches).
async fn show(
    client: &mut TestClient,
    pane: PaneId,
    dir: &Path,
    name: &str,
    bytes: &str,
    done: &str,
) {
    let path = dir.join(name);
    std::fs::write(&path, bytes).unwrap();
    client.type_line(
        pane,
        &format!("cat {}; echo {done}-$((6*7))", path.display()),
    );
    client.wait_text(pane, &format!("{done}-42")).await;
}

fn images(client: &TestClient, pane: PaneId) -> Vec<(KittyPlacement, Option<KittyImage>)> {
    let mut all = client.client.pane_images(pane).unwrap_or_default();
    all.sort_by_key(|(placement, _)| (placement.image_id, placement.placement_id));
    all
}

async fn wait_images(
    client: &mut TestClient,
    pane: PaneId,
    what: &str,
    done: impl Fn(&[(KittyPlacement, Option<KittyImage>)]) -> bool,
) {
    client
        .until(what, |client| done(&images(client, pane)))
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn kitty_graphics_are_mirrored_answered_and_survive_reattach() {
    let state = tempfile::tempdir().unwrap();
    let files = tempfile::tempdir().unwrap();
    let daemon = start(state.path()).await;
    let mut laptop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = laptop.attach_and_follow().await;
    laptop.type_line(pane, "echo ready-$((6*7))");
    laptop.wait_text(pane, "ready-42").await;

    // A query: Ghostty's reply reaches the program like any VT reply, once.
    laptop.type_line(
        pane,
        "stty -icanon -echo min 0 time 20; printf '\\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\\033\\\\'; \
         dd bs=64 count=1 2>/dev/null | tr -c 'A-Za-z0-9=;' '.'; stty sane; echo; echo replied-$((6*7))",
    );
    laptop.wait_text(pane, "replied-42").await;
    let text = laptop.text(pane);
    assert_eq!(text.matches("..Gi=31;OK..").count(), 1, "{text}");

    // A PNG displayed at once (`a=T`), on a screen cleared to a known layout. The client sent
    // no pixel size, so the daemon gave the pane 10×20 px cells: 40×40 px is 4×2 cells.
    let sequence = format!(
        "\x1b[2J\x1b[3;5H{}",
        apc("a=T,f=100,i=1,q=2", &png(40, 40, 200))
    );
    show(
        &mut laptop,
        pane,
        files.path(),
        "png",
        &sequence,
        "shown-png",
    )
    .await;
    wait_images(&mut laptop, pane, "png placed", |all| all.len() == 1).await;
    let (placement, image) = images(&laptop, pane).remove(0);
    let image = image.expect("stored");
    assert_eq!(
        (placement.image_id, placement.cols, placement.rows),
        (1, 4, 2)
    );
    assert_eq!((image.width, image.height), (40, 40));
    assert_eq!(image.pixels.as_deref().map(<[u8]>::len), Some(40 * 40 * 4));
    assert_eq!(image.pixels.unwrap()[..4], [200, 200, 200, 200]);

    // Transmit once, place twice (`a=t`, then `a=p` at two cells), raw RGBA (`f=32`).
    let rgba: Vec<u8> = [255, 0, 0, 255].repeat(20 * 20);
    let sequence = format!(
        "{}\x1b[10;3H{}\x1b[12;30H{}",
        apc("a=t,f=32,s=20,v=20,i=5,q=2", &rgba),
        apc("a=p,i=5,p=1,C=1,q=2", &[]),
        apc("a=p,i=5,p=2,c=6,r=3,C=1,q=2", &[]),
    );
    show(
        &mut laptop,
        pane,
        files.path(),
        "rgba",
        &sequence,
        "shown-rgba",
    )
    .await;
    wait_images(&mut laptop, pane, "two placements of one image", |all| {
        all.iter()
            .filter(|(placement, _)| placement.image_id == 5)
            .count()
            == 2
    })
    .await;
    let placed: Vec<_> = images(&laptop, pane)
        .into_iter()
        .filter(|(placement, _)| placement.image_id == 5)
        .collect();
    let (first, second) = (placed[0].0, placed[1].0);
    assert_eq!(first.viewport.map(|viewport| viewport.0), Some(2));
    assert_eq!((first.cols, first.rows), (2, 1));
    assert_eq!(second.viewport.map(|viewport| viewport.0), Some(29));
    assert_eq!((second.cols, second.rows), (6, 3));
    let row = |placement: KittyPlacement| placement.viewport.unwrap().1;
    assert_eq!(row(second) - row(first), 2);
    let pixels = placed[0].1.clone().and_then(|image| image.pixels).unwrap();
    assert_eq!(pixels, rgba);

    // A chunked transfer (`m=1` … `m=0`), in chunks of whole base64 quads as the spec asks.
    let encoded = data_encoding::BASE64.encode(&png(64, 32, 90));
    let chunks: Vec<&str> = encoded
        .as_bytes()
        .chunks(32)
        .map(|chunk| std::str::from_utf8(chunk).unwrap())
        .collect();
    assert!(chunks.len() > 2);
    let mut sequence = String::from("\x1b[20;1H");
    for (i, chunk) in chunks.iter().enumerate() {
        let more = u8::from(i + 1 < chunks.len());
        let params = if i == 0 { "a=T,f=100,i=9,q=2," } else { "" };
        sequence += &format!("\x1b_G{params}m={more};{chunk}\x1b\\");
    }
    show(
        &mut laptop,
        pane,
        files.path(),
        "chunked",
        &sequence,
        "shown-chunks",
    )
    .await;
    wait_images(&mut laptop, pane, "chunked image", |all| {
        all.iter().any(|(placement, image)| {
            placement.image_id == 9
                && image
                    .as_ref()
                    .is_some_and(|image| (image.width, image.height) == (64, 32))
        })
    })
    .await;

    // Deleting image 5 with its placements (`a=d,d=I`).
    show(
        &mut laptop,
        pane,
        files.path(),
        "delete",
        &apc("a=d,d=I,i=5,q=2", &[]),
        "deleted",
    )
    .await;
    wait_images(&mut laptop, pane, "image 5 deleted", |all| {
        all.iter().all(|(placement, _)| placement.image_id != 5)
    })
    .await;
    assert_eq!(images(&laptop, pane).len(), 2);

    // A client attaching now restores the images from the snapshot, pixels included.
    let before = images(&laptop, pane);
    let mut tablet = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane_b = tablet.attach_and_follow().await;
    assert_eq!(pane_b, pane);
    wait_images(&mut tablet, pane, "images restored with pixels", |all| {
        all.len() == 2
            && all
                .iter()
                .all(|(_, image)| image.as_ref().is_some_and(|image| image.pixels.is_some()))
    })
    .await;
    let after = images(&tablet, pane);
    for ((placement, image), (restored_placement, restored)) in before.iter().zip(&after) {
        assert_eq!(placement, restored_placement);
        let (image, restored) = (image.as_ref().unwrap(), restored.as_ref().unwrap());
        assert_eq!(
            (image.width, image.height, &image.pixels),
            (restored.width, restored.height, &restored.pixels)
        );
    }

    // And a reconnect of the first client resumes with them too.
    drop(laptop);
    let mut laptop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    laptop.attach_and_follow().await;
    wait_images(&mut laptop, pane, "images after reconnect", |all| {
        all.len() == 2
            && all
                .iter()
                .all(|(_, image)| image.as_ref().is_some_and(|image| image.pixels.is_some()))
    })
    .await;
    drop((laptop, tablet));
    daemon.shutdown().await;
}

/// A client's mirror keeps the images its host keeps: the daemon sends its
/// `image_storage_mb`, and an image the host evicts goes from the mirror too.
#[tokio::test(flavor = "multi_thread")]
async fn mirrors_follow_the_hosts_image_storage() {
    let state = tempfile::tempdir().unwrap();
    let files = tempfile::tempdir().unwrap();
    // Room for two 2×2 RGBA images (16 bytes each), not three.
    let daemon =
        crate::support::start_with(state.path(), |config| config.image_storage_bytes = 40).await;
    let mut laptop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = laptop.attach_and_follow().await;
    laptop.type_line(pane, "echo ready-$((6*7))");
    laptop.wait_text(pane, "ready-42").await;
    assert_eq!(laptop.client.image_storage_limit(), 40);

    let rgba = [0, 0, 255, 255].repeat(4);
    let sequence: String = (1..=3)
        .map(|id| {
            format!(
                "\x1b[{id};1H{}",
                apc(&format!("a=T,f=32,s=2,v=2,i={id},q=2"), &rgba)
            )
        })
        .collect();
    show(
        &mut laptop,
        pane,
        files.path(),
        "three",
        &sequence,
        "shown-three",
    )
    .await;
    wait_images(&mut laptop, pane, "the third image", |all| {
        all.iter().any(|(placement, _)| placement.image_id == 3)
    })
    .await;
    let stored: Vec<u32> = images(&laptop, pane)
        .iter()
        .filter(|(_, image)| image.is_some())
        .map(|(placement, _)| placement.image_id)
        .collect();
    assert_eq!(stored, [2, 3], "the host evicted the oldest image");
}
