use super::*;

fn frame(text: &[u8], masked: bool, opcode: u8, final_frame: bool) -> Vec<u8> {
    let mut bytes = vec![opcode | if final_frame { 128 } else { 0 }];
    let mask = if masked { 128 } else { 0 };
    if text.len() < 126 {
        bytes.push(mask | text.len() as u8);
    } else {
        bytes.push(mask | 126);
        bytes.extend_from_slice(&(text.len() as u16).to_be_bytes());
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

#[test]
fn every_chunk_boundary_keeps_the_same_messages() {
    for masked in [false, true] {
        let mut bytes = if masked {
            b"GET / HTTP/1.1\r\n\r\n".to_vec()
        } else {
            b"HTTP/1.1 101 Switching Protocols\r\n\r\n".to_vec()
        };
        bytes.extend(frame(b"hello ", masked, 1, false));
        bytes.extend(frame(b"ping", masked, 9, true));
        bytes.extend(frame("world 🐧".as_bytes(), masked, 0, true));
        bytes.extend(frame(&[b'a'; 128], masked, 1, true));
        for split in 0..=bytes.len() {
            let mut decoder = Decoder::new(masked);
            let mut received = Vec::new();
            decoder
                .feed(&bytes[..split], |text| received.push(text.to_string()))
                .unwrap();
            decoder
                .feed(&bytes[split..], |text| received.push(text.to_string()))
                .unwrap();
            assert_eq!(received, ["hello world 🐧".to_string(), "a".repeat(128)]);
        }
    }
}

#[test]
fn wrong_masks_compression_invalid_utf8_and_large_declared_lengths_fail_native_only() {
    for bytes in [
        frame(b"text", true, 1, true),
        vec![0xc1, 0],
        vec![0x81, 1, 255],
        vec![0x81, 127, 0, 0, 0, 0, 0, 1, 0, 1],
    ] {
        let mut decoder = Decoder::new(false);
        decoder
            .feed(b"HTTP/1.1 101 Switching Protocols\r\n\r\n", |_| {})
            .unwrap();
        assert!(
            decoder
                .feed(&bytes, |_| panic!("invalid data was emitted"))
                .is_err()
        );
    }
}

#[test]
fn fragmented_message_and_handshake_bounds_are_enforced() {
    let mut decoder = Decoder::new(false);
    assert!(decoder.feed(&vec![b'a'; MAX_HEADER + 1], |_| {}).is_err());
    let mut decoder = Decoder::new(false);
    decoder
        .feed(b"HTTP/1.1 101 Switching Protocols\r\n\r\n", |_| {})
        .unwrap();
    decoder
        .feed(&frame(&vec![b'a'; 40000], false, 1, false), |_| {})
        .unwrap();
    assert!(
        decoder
            .feed(&frame(&vec![b'b'; 40000], false, 0, true), |_| {})
            .is_err()
    );
}
