nonisolated struct RenderedPage: Sendable {
    private(set) var items: [String: RenderedChatRows]
    private(set) var cost: LRUCost
    var changedRows: [ChatRow] = []

    init(items: [String: RenderedChatRows] = [:], cost: LRUCost = LRUCost()) {
        self.items = items
        self.cost = cost
    }

    mutating func remove(_ identifier: String) {
        guard let previous = items.removeValue(forKey: identifier) else { return }
        cost = LRUCost(bytes: cost.bytes - previous.cost.bytes, units: cost.units - previous.cost.units)
    }

    mutating func store(_ rendered: RenderedChatRows, for identifier: String) -> Bool {
        let previous = items[identifier]?.cost ?? LRUCost()
        let bytes = cost.bytes - previous.bytes
        let units = cost.units - previous.units
        guard bytes <= ChatRenderLimits.bytesPerPage, units <= ChatRenderLimits.rowsPerPage,
              rendered.cost.bytes <= ChatRenderLimits.bytesPerPage - bytes,
              rendered.cost.units <= ChatRenderLimits.rowsPerPage - units else { return false }
        cost = LRUCost(bytes: bytes + rendered.cost.bytes, units: units + rendered.cost.units)
        items[identifier] = rendered
        return true
    }
}
