use proto::InputPayload;

#[test]
fn generated_input_uses_the_appended_payload_tag() {
    assert_eq!(proto::DaemonFeatures::GENERATED_INPUT.0, 1 << 25);
    let golden = [5, 3, 0x1b, 0x5b, 0x49];
    let payload: InputPayload = postcard::from_bytes(&golden).unwrap();
    assert_eq!(postcard::to_allocvec(&payload).unwrap(), golden);
    assert_eq!(
        payload,
        InputPayload::GeneratedBytes(vec![0x1b, 0x5b, 0x49])
    );
}
