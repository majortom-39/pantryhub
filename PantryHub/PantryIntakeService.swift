import Foundation

// =============================================================================
// MARK: - Pantry Intake service
// =============================================================================
// One client for all four "add to pantry" doors. Every door returns the SAME
// [PantryItem] shape, so the review screen and the rest of the app never need
// to know how an item was captured.
//
//   scanImages([jpeg Data])  → vision extraction (photos / receipts / gallery)
//   lookupBarcodes([String]) → Open Food Facts product lookup
//   parseVoice(String)       → structure a spoken grocery list
//
// New items default to a single FULL container; expiry is only filled when the
// backend knew or estimated it (estimates are flagged so the UI can nudge).

/// One item as `pantry-intake` returns it (before we make it a PantryItem).
private struct IntakeItemDTO: Decodable {
    let name: String
    let brand: String?
    let category: String?
    let quantity: String?
    let image_kind: String?
    let expiry: String?
    let expiry_estimated: Bool?
    let identified: Bool?
    let barcode: String?
    let note: String?
}

private struct IntakeResponse: Decodable { let items: [IntakeItemDTO] }

struct PantryIntakeService {
    static let shared = PantryIntakeService()

    private struct ScanBody: Encodable { let action = "scan_images"; let images: [String] }
    private struct BarcodeBody: Encodable { let action = "lookup_barcode"; let barcodes: [String] }
    private struct VoiceBody: Encodable { let action = "parse_voice"; let transcript: String }

    /// Vision extraction from one or more photos (camera shots or gallery picks).
    /// Images are JPEG-compressed and base64-encoded before sending.
    func scanImages(_ images: [Data]) async throws -> [PantryItem] {
        let encoded = images.map { $0.base64EncodedString() }
        let resp: IntakeResponse = try await BackendHTTP.request(
            url: BackendConfig.pantryIntakeEndpoint,
            body: ScanBody(images: encoded),
            timeout: 90)
        return resp.items.map(toPantryItem)
    }

    /// Look up scanned barcodes. Misses come back flagged `needsReview`.
    func lookupBarcodes(_ barcodes: [String]) async throws -> [PantryItem] {
        let resp: IntakeResponse = try await BackendHTTP.request(
            url: BackendConfig.pantryIntakeEndpoint,
            body: BarcodeBody(barcodes: barcodes),
            timeout: 45)
        return resp.items.map(toPantryItem)
    }

    /// Structure a spoken grocery list into clean items.
    func parseVoice(_ transcript: String) async throws -> [PantryItem] {
        let resp: IntakeResponse = try await BackendHTTP.request(
            url: BackendConfig.pantryIntakeEndpoint,
            body: VoiceBody(transcript: transcript),
            timeout: 60)
        return resp.items.map(toPantryItem)
    }

    // MARK: Mapping

    private func toPantryItem(_ dto: IntakeItemDTO) -> PantryItem {
        let identified = dto.identified ?? true
        let category = PantryCategory(backendSlug: dto.category ?? "produce")
        let quantity = dto.quantity ?? ""
        let unit = Self.defaultFullnessUnit(name: dto.name, category: category,
                                            imageKind: dto.image_kind ?? "generic", quantity: quantity)
        // An unidentified item gets a placeholder name the review row turns amber.
        let name = identified ? dto.name : (dto.name.isEmpty ? "Unknown item" : dto.name)
        return PantryItem(
            name: name,
            brand: dto.brand ?? "",
            imageKind: ItemImageKind(backendSlug: dto.image_kind ?? "generic"),
            category: category,
            quantity: quantity,
            fullnessLevels: [1.0],                       // default: one full container
            fullnessUnit: unit,
            expiry: PantryDate.parse(dto.expiry),
            needsReview: !identified,
            expiryEstimated: dto.expiry_estimated ?? false,
            intakeNote: dto.note ?? "")
    }

    /// Choose the fullness metaphor's unit: a piece count for discrete whole
    /// foods (eggs, fruit), otherwise percentage (the draggable jar). Liquids
    /// stay on the jar too. The user can always change it in the editor.
    static func defaultFullnessUnit(name: String, category: PantryCategory,
                                    imageKind: String, quantity: String) -> String {
        // Pick the unit by what the ingredient ACTUALLY IS — ingredient type wins
        // over the package text, and "%" is only the last-resort fallback for when
        // we genuinely can't tell. Order matters.
        let n = name.lowercased()
        let q = quantity.lowercased()

        // 1) Countable whole foods → pieces, regardless of any guessed weight.
        let countable = ["egg", "onion", "apple", "banana", "lemon", "lime", "orange",
                         "potato", "tomato", "avocado", "carrot", "mango", "pear",
                         "pepper", "chilli", "chili", "garlic", "cucumber", "peach",
                         "plum", "kiwi", "can", "bottle", "packet", "bar",
                         "loaf", "tin", "dozen", "clove"]
        if countable.contains(where: { n.contains($0) }) { return "pieces" }
        if imageKind == "generic" && category == .produce { return "pieces" }

        // 2) Match the real measure it's sold in — volume vs weight.
        if q.range(of: #"\b(ml|l|litre|liter|cl|fl ?oz)\b"#, options: .regularExpression) != nil { return "ml" }
        if q.range(of: #"\b(g|kg|mg|oz|lb|gram|gm)\b"#, options: .regularExpression) != nil { return "g" }

        // 3) Category hints when the size text gives nothing to go on.
        switch category {
        case .drinks:        return "ml"
        case .meat, .grains: return "g"
        case .produce:       return "pieces"
        default:             break
        }

        // 4) Genuinely unsure → percentage jar.
        return "%"
    }
}
