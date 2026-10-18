//! Smoke test: the static archive links and a snapshot round-trips.

use core::ptr;

use ghostty_vt_sys::*;

#[test]
fn snapshot_round_trip_links_and_runs() {
    unsafe {
        let mut term: GhosttyTerminal = ptr::null_mut();
        assert_eq!(
            ghostty_terminal_new(ptr::null(), &mut term, 80, 24),
            GhosttyResult_GHOSTTY_SUCCESS
        );
        let input = b"hello \x1b[1;31mworld\x1b[0m\r\n";
        ghostty_terminal_vt_write(term, input.as_ptr(), input.len());

        let (mut buf, mut len): (*mut u8, usize) = (ptr::null_mut(), 0);
        assert_eq!(
            ghostty_snapshot_encode_alloc(term, ptr::null(), &mut buf, &mut len),
            GhosttyResult_GHOSTTY_SUCCESS
        );
        assert!(len > 0);

        let mut decoder: GhosttySnapshotDecoder = ptr::null_mut();
        assert_eq!(
            ghostty_snapshot_decoder_new_buf(ptr::null(), &mut decoder, buf, len),
            GhosttyResult_GHOSTTY_SUCCESS
        );
        let mut restored: GhosttyTerminal = ptr::null_mut();
        assert_eq!(
            ghostty_snapshot_decoder_decode(decoder, &mut restored),
            GhosttyResult_GHOSTTY_SUCCESS
        );
        assert!(!restored.is_null());

        ghostty_snapshot_decoder_free(decoder);
        ghostty_free(ptr::null(), buf, len);
        ghostty_terminal_free(restored);
        ghostty_terminal_free(term);
    }
}
