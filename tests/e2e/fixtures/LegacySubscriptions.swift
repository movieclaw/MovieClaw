import Foundation

// Compile with the App's existing generated models, without regenerating them.
struct Envelope<Value: Decodable>: Decodable {
    let data: Value
}

@main
struct LegacySubscriptions {
    static func main() {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let decoder = JSONDecoder()
            switch CommandLine.arguments[1] {
            case "detail":
                _ = try decoder.decode(Envelope<API.SubscriptionDetailView>.self, from: data)
            case "list":
                _ = try decoder.decode(Envelope<[API.SubscriptionView]>.self, from: data)
            case "create":
                _ = try decoder.decode(Envelope<API.SubscriptionCreateView>.self, from: data)
            case "upgrade":
                _ = try decoder.decode(Envelope<API.UpgradeRunView>.self, from: data)
            default:
                exit(2)
            }
            print("decoded \(CommandLine.arguments[1])")
        } catch {
            print(error)
            exit(1)
        }
    }
}
