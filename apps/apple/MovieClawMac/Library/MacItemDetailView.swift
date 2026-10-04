import SwiftUI

struct MacItemDetailView: View {
    let libraryId: Int
    let itemId: Int
    var body: some View { Text("详情 \(itemId)") }
}

struct MacPersonView: View {
    let tmdbId: Int
    let name: String
    let avatar: String?
    let fromItem: Int?
    var body: some View { Text(name) }
}
