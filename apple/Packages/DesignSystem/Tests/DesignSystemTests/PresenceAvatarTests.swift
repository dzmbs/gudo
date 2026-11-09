import SwiftUI
import Testing
@testable import DesignSystem

struct PresenceAvatarTests {
    @Test func initialsAreDarkOnLightColoursAndLightOnDarkOnes() {
        #expect(PresenceAvatar.ink(on: Color(red: 0.75, green: 0.78, blue: 0.45).resolve(in: EnvironmentValues())) == .black)
        #expect(PresenceAvatar.ink(on: Color(red: 0.16, green: 0.31, blue: 0.62).resolve(in: EnvironmentValues())) == .white)
    }
}
