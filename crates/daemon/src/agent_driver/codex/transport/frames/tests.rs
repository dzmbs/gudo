use super::*;

fn frame(text: &[u8], direction: Direction, opcode: u8, final_frame: bool) -> Vec<u8> {
    let masked = direction.is_masked();
    let mut bytes = vec![opcode | if final_frame { 128 } else { 0 }];
    let mask = if masked { 128 } else { 0 };
    if text.len() < 126 {
        bytes.push(mask | text.len() as u8);
    } else if let Ok(length) = u16::try_from(text.len()) {
        bytes.push(mask | 126);
        bytes.extend_from_slice(&length.to_be_bytes());
    } else {
        bytes.push(mask | 127);
        bytes.extend_from_slice(&(text.len() as u64).to_be_bytes());
    }
    if masked {
        bytes.extend_from_slice(&[1, 2, 3, 4]);
    }
    bytes.extend(text.iter().enumerate().map(|(index, byte)| {
        if masked {
            byte ^ [1, 2, 3, 4][index % 4]
        } else {
            *byte
        }
    }));
    bytes
}

fn handshake(direction: Direction) -> Vec<u8> {
    match direction {
        Direction::FromTui => b"GET / HTTP/1.1\r\n\r\n".to_vec(),
        Direction::FromServer => b"HTTP/1.1 101 Switching Protocols\r\n\r\n".to_vec(),
    }
}

fn collect(received: &mut Vec<String>) -> impl FnMut(Observed<'_>) + '_ {
    |observed| match observed {
        Observed::Text(text) => received.push(text.to_string()),
        Observed::Skipped => received.push("<skipped>".into()),
    }
}

#[test]
fn every_chunk_boundary_keeps_the_same_messages() {
    for direction in [Direction::FromServer, Direction::FromTui] {
        let mut bytes = handshake(direction);
        bytes.extend(frame(b"hello ", direction, 1, false));
        bytes.extend(frame(b"ping", direction, 9, true));
        bytes.extend(frame("world 🐧".as_bytes(), direction, 0, true));
        bytes.extend(frame(&[b'a'; 128], direction, 1, true));
        for split in 0..=bytes.len() {
            let mut decoder = Decoder::new(direction);
            let mut received = Vec::new();
            decoder
                .feed(&bytes[..split], collect(&mut received))
                .unwrap();
            decoder
                .feed(&bytes[split..], collect(&mut received))
                .unwrap();
            assert_eq!(received, ["hello world 🐧".to_string(), "a".repeat(128)]);
        }
    }
}

#[test]
fn wrong_masks_compression_and_invalid_utf8_fail_native_only() {
    for bytes in [
        frame(b"text", Direction::FromTui, 1, true),
        vec![0xc1, 0],
        vec![0x81, 1, 255],
        vec![0x81, 127, 0x80, 0, 0, 0, 0, 0, 0, 1],
    ] {
        let mut decoder = Decoder::new(Direction::FromServer);
        decoder
            .feed(&handshake(Direction::FromServer), |_| {})
            .unwrap();
        assert!(
            decoder
                .feed(&bytes, |_| panic!("invalid data was emitted"))
                .is_err()
        );
    }
}

#[test]
fn handshake_bounds_are_enforced() {
    let mut decoder = Decoder::new(Direction::FromServer);
    assert!(decoder.feed(&vec![b'a'; MAX_HEADER + 1], |_| {}).is_err());
}

#[test]
fn messages_over_the_observation_limit_are_skipped_and_decoding_continues() {
    for direction in [Direction::FromServer, Direction::FromTui] {
        let large = vec![b'a'; MAX_MESSAGE / 2 + 1];
        let mut bytes = handshake(direction);
        bytes.extend(frame(&large, direction, 1, false));
        bytes.extend(frame(b"ping", direction, 9, true));
        bytes.extend(frame(&large, direction, 0, true));
        bytes.extend(frame(&vec![b'b'; MAX_MESSAGE + 1], direction, 1, true));
        bytes.extend(frame(b"after", direction, 1, true));
        let mut received = Vec::new();
        let mut decoder = Decoder::new(direction);
        for chunk in bytes.chunks(16 * 1024) {
            decoder.feed(chunk, collect(&mut received)).unwrap();
        }
        assert_eq!(received, ["<skipped>", "<skipped>", "after"]);
        assert!(decoder.buffer.len() < 16 * 1024);
    }
}

#[test]
fn a_message_of_one_mebibyte_of_output_is_observed() {
    let output = "x".repeat(1024 * 1024 + 4096);
    let mut bytes = handshake(Direction::FromServer);
    bytes.extend(frame(output.as_bytes(), Direction::FromServer, 1, true));
    let mut received = Vec::new();
    Decoder::new(Direction::FromServer)
        .feed(&bytes, collect(&mut received))
        .unwrap();
    assert_eq!(received, [output]);
}
