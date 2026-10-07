import Foundation

enum TweakState: Equatable {
  case applied, notApplied, partial
  /// Another profile (usually an MDM) controls the setting.
  case managed
  /// This version of macOS doesn't have the setting.
  case unsupported
}

/// What the Mac looks like right now, read once per refresh.
struct Snapshot {
  var profile = Profile.installed()
  var disabledServices = Engine.disabledServices()
  var dockApps = Engine.dockApps()

  func state(_ tweak: Tweak) -> TweakState {
    guard tweak.supported else { return .unsupported }
    if tweak.changes.contains(where: { managedElsewhere($0, tweak) }) { return .managed }
    let done = tweak.changes.filter(applied).count
    return done == tweak.changes.count ? .applied : done == 0 ? .notApplied : .partial
  }

  func applied(_ change: Change) -> Bool {
    switch change {
    case .restriction(let key):
      return Prefs.isForced("com.apple.applicationaccess", key)
        && PlistValue.bool(false).matches(Prefs.read("com.apple.applicationaccess", key))
    case .forced(let domain, let key, let value):
      return Prefs.isForced(domain, key) && value.matches(Prefs.read(domain, key))
    case .pref(let domain, let key, let value, let host):
      return value.matches(Prefs.read(domain, key, currentHost: host))
    case .service(let label):
      return disabledServices.contains(label)
    case .dockRemove(let ids):
      return dockApps.isDisjoint(with: ids)
    case .showLibrary:
      return !Engine.libraryHidden()
    }
  }

  /// A setting forced by something other than our profile can't be changed here.
  func managedElsewhere(_ change: Change, _ tweak: Tweak) -> Bool {
    let ours = profile.on && profile.tweaks.contains(tweak.id)
    switch change {
    case .restriction(let key): return !ours && Prefs.isForced("com.apple.applicationaccess", key)
    case .forced(let domain, let key, _): return !ours && Prefs.isForced(domain, key)
    case .pref(let domain, let key, _, _): return Prefs.isForced(domain, key)
    default: return false
    }
  }

  var appliedTweaks: Set<String> { Set(Tweaks.all.filter { state($0) == .applied }.map(\.id)) }
}

/// Everything one press of Apply does.
struct Plan {
  var apply: [Tweak] = []
  var revert: [Tweak] = []
  /// The profile to install, when it has to change. An empty one means remove it.
  var profile: Profile.Contents?
  /// Model sets to remove once the profile is in place.
  var models: [String] = []

  var isEmpty: Bool { apply.isEmpty && revert.isEmpty && profile == nil && models.isEmpty }

  /// From the tweaks that should end up applied and what Apple Intelligence
  /// should look like (nil leaves it alone, a set turns it off except those).
  /// A partly applied tweak is often the person's own setting, so it is only
  /// undone when named in `undo`.
  static func make(
    wanted: Set<String>, ai: Set<String>?, undo: Set<String> = [], snapshot s: Snapshot = Snapshot(),
    state read: ((Tweak) -> TweakState)? = nil
  ) -> Plan {
    let stateOf = read ?? s.state
    var plan = Plan()
    func keepsPartial(_ tweak: Tweak) -> Bool { stateOf(tweak) == .partial && !undo.contains(tweak.id) }
    for tweak in Tweaks.all {
      let state = stateOf(tweak)
      guard state != .managed && state != .unsupported else { continue }
      if wanted.contains(tweak.id) && state != .applied {
        plan.apply.append(tweak)
      } else if !wanted.contains(tweak.id) && state != .notApplied && !keepsPartial(tweak) {
        plan.revert.append(tweak)
      }
    }
    let profileTweaks = Set(Tweaks.all.filter {
      $0.inProfile && stateOf($0) != .managed && $0.supported
        && (wanted.contains($0.id) || (keepsPartial($0) && s.profile.tweaks.contains($0.id)))
    }.map(\.id))
    let target = Profile.Contents(ai: ai, tweaks: profileTweaks)
    let current = s.profile.contents ?? Profile.Contents(ai: nil, tweaks: [])
    if target != current { plan.profile = target }
    // Models go when Apple Intelligence is being turned off now. Leftovers
    // from an earlier run are `removemacai off`'s job.
    if let kept = ai, ai != current.ai {
      plan.models = Catalog.setsToRemove(keeping: kept).filter { Models.present($0) }
    }
    return plan
  }
}

enum Engine {
  // MARK: journal

  /// The value each setting had before RemoveMacAI changed it.
  struct Journal: Codable {
    var entries: [String: Entry] = [:]

    struct Entry: Codable {
      var tweak: String
      var date: Date
      var previous: Previous
    }

    enum Previous: Codable {
      case pref(PlistValue?)
      case service(disabled: Bool)
      case dock([DockTile])
      case hidden(Bool)
      case background(disabled: Bool)
    }
  }

  struct DockTile: Codable {
    let index: Int
    let plist: Data
  }

  static var folder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RemoveMacAI")
  }
  static var journalURL: URL { folder.appendingPathComponent("journal.json") }

  static func loadJournal() -> Journal {
    guard let data = try? Data(contentsOf: journalURL) else { return Journal() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(Journal.self, from: data)) ?? Journal()
  }

  static func save(_ journal: Journal) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? encoder.encode(journal).write(to: journalURL, options: .atomic)
  }

  // MARK: reading the system

  static let uid = getuid()

  /// Services the user's session has switched off.
  static func disabledServices() -> Set<String> {
    let out = Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).output
    var labels = Set<String>()
    for line in out.split(separator: "\n") {
      let parts = line.components(separatedBy: "=>")
      guard parts.count == 2 else { continue }
      let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      let value = parts[1].trimmingCharacters(in: .whitespaces)
      if value == "disabled" || value == "true" { labels.insert(label) }
    }
    return labels
  }

  static func dockTiles() -> [[String: Any]] {
    Prefs.read("com.apple.dock", "persistent-apps") as? [[String: Any]] ?? []
  }

  static func bundleID(_ tile: [String: Any]) -> String? {
    (tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
  }

  static func dockApps() -> Set<String> { Set(dockTiles().compactMap(bundleID)) }

  static var library: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library") }

  static func libraryHidden() -> Bool {
    (try? library.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? true
  }

  static func setLibraryHidden(_ hidden: Bool) -> Bool {
    var values = URLResourceValues()
    values.isHidden = hidden
    var url = library
    return (try? url.setResourceValues(values)) != nil
  }

  // MARK: changing it

  /// Applies the settings a tweak changes outside the profile. Returns problems.
  static func apply(_ tweak: Tweak, journal: inout Journal) -> [String] {
    var problems: [String] = []
    for change in tweak.changes {
      let key = change.key
      switch change {
      case .restriction, .forced:
        continue
      case .pref(let domain, let k, let value, let host):
        if journal.entries[key] == nil {
          let previous = PlistValue(Prefs.userValue(domain, k, currentHost: host))
          journal.entries[key] = .init(tweak: tweak.id, date: Date(), previous: .pref(previous))
        }
        Prefs.write(domain, k, value, currentHost: host)
        if !value.matches(Prefs.read(domain, k, currentHost: host)) {
          problems.append("\(domain) \(k) did not change")
        }
      case .service(let label):
        if journal.entries[key] == nil {
          journal.entries[key] = .init(
            tweak: tweak.id, date: Date(), previous: .service(disabled: disabledServices().contains(label)))
        }
        let disabled = Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(label)"])
        if !disabled.ok { problems.append("could not disable \(label): \(disabled.output.trimmed)") }
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
      case .dockRemove(let ids):
        let tiles = dockTiles()
        var kept: [[String: Any]] = []
        var removed: [DockTile] = []
        for (i, tile) in tiles.enumerated() {
          if let id = bundleID(tile), ids.contains(id),
            let data = try? PropertyListSerialization.data(fromPropertyList: tile, format: .binary, options: 0)
          {
            removed.append(DockTile(index: i, plist: data))
          } else {
            kept.append(tile)
          }
        }
        guard !removed.isEmpty else { continue }
        var earlier: [DockTile] = []
        if case .dock(let tiles)? = journal.entries[key]?.previous { earlier = tiles }
        journal.entries[key] = .init(tweak: tweak.id, date: Date(), previous: .dock(earlier + removed))
        CFPreferencesSetAppValue("persistent-apps" as CFString, kept as CFArray, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
      case .showLibrary:
        if journal.entries[key] == nil {
          journal.entries[key] = .init(tweak: tweak.id, date: Date(), previous: .hidden(libraryHidden()))
        }
        if !setLibraryHidden(false) { problems.append("could not show ~/Library") }
      }
    }
    return problems
  }

  /// Puts back what a tweak changed outside the profile: the value from
  /// before RemoveMacAI touched it, or the macOS default when there is none.
  static func revert(_ tweak: Tweak, journal: inout Journal) -> [String] {
    var problems: [String] = []
    for change in tweak.changes {
      let key = change.key
      let entry = journal.entries[key]
      switch change {
      case .restriction, .forced:
        continue
      case .pref(let domain, let k, _, let host):
        var previous: PlistValue? = nil
        if case .pref(let value)? = entry?.previous { previous = value }
        Prefs.write(domain, k, previous, currentHost: host)
      case .service(let label):
        if case .service(let wasDisabled)? = entry?.previous, wasDisabled { break }
        let enabled = Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
        if !enabled.ok { problems.append("could not enable \(label): \(enabled.output.trimmed)") }
        let plist = "/System/Library/LaunchAgents/\(label).plist"
        if FileManager.default.fileExists(atPath: plist),
          !Shell.run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]).ok
        {
          Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
        }
      case .dockRemove:
        guard case .dock(let removed)? = entry?.previous else { break }
        var tiles = dockTiles()
        let present = Set(tiles.compactMap(bundleID))
        for tile in removed.sorted(by: { $0.index < $1.index }) {
          guard let dict = try? PropertyListSerialization.propertyList(from: tile.plist, format: nil) as? [String: Any],
            let id = bundleID(dict), !present.contains(id)
          else { continue }
          tiles.insert(dict, at: min(tile.index, tiles.count))
        }
        CFPreferencesSetAppValue("persistent-apps" as CFString, tiles as CFArray, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
      case .showLibrary:
        var hidden = true
        if case .hidden(let was)? = entry?.previous { hidden = was }
        if !setLibraryHidden(hidden) { problems.append("could not hide ~/Library") }
      }
      journal.entries[key] = nil
    }
    return problems
  }

  /// Applies and reverts the tweaks outside the profile, then restarts what
  /// needs it. The profile and the models are the caller's next steps.
  static func runLocal(_ plan: Plan) -> [String] {
    var journal = loadJournal()
    var problems: [String] = []
    for tweak in plan.revert { problems += revert(tweak, journal: &journal).map { "\(tweak.title): \($0)" } }
    for tweak in plan.apply { problems += apply(tweak, journal: &journal).map { "\(tweak.title): \($0)" } }
    save(journal)
    let touched = plan.apply + plan.revert
    Shell.restart(touched.filter { $0.changes.contains { !$0.inProfile } }.flatMap(\.restart))
    return problems
  }

  /// Undoes every change in the journal, including ones from tweaks that
  /// are no longer in the catalog.
  static func revertAll() -> [String] {
    var journal = loadJournal()
    var problems: [String] = []
    let ids = Set(journal.entries.values.map(\.tweak))
    var restart: [String] = []
    for id in ids.sorted() {
      if let tweak = Tweaks.tweak(id) {
        problems += revert(tweak, journal: &journal)
        restart += tweak.restart
      } else if id.hasPrefix("background:") {
        problems += BackgroundItems.revert(id, journal: &journal)
      }
    }
    save(journal)
    Shell.restart(restart)
    return problems
  }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
