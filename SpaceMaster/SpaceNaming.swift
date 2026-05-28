import Foundation

final class SpaceTitleResolver {
    private let manualAliasStore: SpaceAliasStore
    private let automaticAliasStore: SpaceAliasStore

    init(
        manualAliasStore: SpaceAliasStore = SpaceAliasStore(kind: .manual),
        automaticAliasStore: SpaceAliasStore = SpaceAliasStore(kind: .automatic)
    ) {
        self.manualAliasStore = manualAliasStore
        self.automaticAliasStore = automaticAliasStore
    }

    func title(for space: MenubarSpace?, spaceNumber: Int) -> String {
        title(for: space?.identity, spaceNumber: spaceNumber)
    }

    func title(for identity: MenubarSpaceIdentity?, spaceNumber: Int) -> String {
        guard let identity else {
            return defaultTitle(for: spaceNumber)
        }

        return manualAliasStore.alias(for: identity)
            ?? automaticAliasStore.alias(for: identity)
            ?? defaultTitle(for: spaceNumber)
    }

    func defaultTitle(for spaceNumber: Int) -> String {
        "Desktop \(spaceNumber)"
    }

    func manualAlias(for identity: MenubarSpaceIdentity) -> String? {
        manualAliasStore.alias(for: identity)
    }

    @discardableResult
    func setManualAlias(_ alias: String?, for identity: MenubarSpaceIdentity) -> Bool {
        manualAliasStore.setAlias(alias, for: identity)
    }

    @discardableResult
    func setAutomaticAlias(_ alias: String?, for identity: MenubarSpaceIdentity) -> Bool {
        automaticAliasStore.setAlias(alias, for: identity)
    }
}

final class SpaceAliasStore {
    enum Kind {
        case manual
        case automatic
    }

    private enum Keys {
        static let manualAliases = "spaceAliasesByStableID"
        static let automaticAliases = "spaceAutomaticAliasesByStableID"
        static let legacyNumberedAliases = "spaceAliases"
    }

    private let kind: Kind
    private let defaults: UserDefaults

    init(kind: Kind, defaults: UserDefaults = .standard) {
        self.kind = kind
        self.defaults = defaults

        if kind == .manual {
            clearLegacyAliasesIfNeeded()
        }
    }

    func alias(for identity: MenubarSpaceIdentity) -> String? {
        aliases()[identity.aliasKey]
    }

    @discardableResult
    func setAlias(_ alias: String?, for identity: MenubarSpaceIdentity) -> Bool {
        let normalizedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updatedAliases = aliases()
        let key = identity.aliasKey
        let resolvedAlias = normalizedAlias?.isEmpty == false ? normalizedAlias : nil

        if updatedAliases[key] == resolvedAlias {
            return false
        }

        if let resolvedAlias {
            updatedAliases[key] = resolvedAlias
        } else {
            updatedAliases.removeValue(forKey: key)
        }

        if updatedAliases.isEmpty {
            defaults.removeObject(forKey: aliasesKey)
        } else {
            defaults.set(updatedAliases, forKey: aliasesKey)
        }

        return true
    }

    private func clearLegacyAliasesIfNeeded() {
        guard defaults.object(forKey: Keys.legacyNumberedAliases) != nil else {
            return
        }

        defaults.removeObject(forKey: Keys.legacyNumberedAliases)
    }

    private func aliases() -> [String: String] {
        defaults.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
    }

    private var aliasesKey: String {
        switch kind {
        case .manual:
            Keys.manualAliases
        case .automatic:
            Keys.automaticAliases
        }
    }
}
