import Foundation

/// A humane identity for an otherwise anonymous worktree.
///
/// The catalog deliberately alternates regions and disciplines. New workspaces
/// walk the catalog without reuse before cycling, so the sidebar doesn't become
/// a list drawn from one country or one branch of science.
public struct ResearchIdentity: Sendable, Codable, Hashable, Identifiable {
    public var id: String { slug }
    public var name: String
    public var slug: String
    public var region: String
    public var field: String
    public var fact: String
    public var researchTitles: [String]

    public init(
        name: String,
        slug: String,
        region: String,
        field: String,
        fact: String,
        researchTitles: [String]
    ) {
        self.name = name
        self.slug = slug
        self.region = region
        self.field = field
        self.fact = fact
        self.researchTitles = researchTitles
    }

    public static let catalog: [ResearchIdentity] = [
        .init(name: "Ibn al-Haytham", slug: "ibn-al-haytham", region: "Iraq", field: "Optics",
              fact: "He made controlled experiments central to studying light and vision, and his Book of Optics reshaped the field.",
              researchTitles: ["Book of Optics", "Experimental Light"]),
        .init(name: "Janaki Ammal", slug: "janaki-ammal", region: "India", field: "Cytogenetics",
              fact: "Her chromosome research helped breed hardier sugarcane and expanded the scientific record of India’s plant diversity.",
              researchTitles: ["Chromosome Gardens", "Sugarcane Genetics"]),
        .init(name: "Tu Youyou", slug: "tu-youyou", region: "China", field: "Pharmaceutical chemistry",
              fact: "She drew on historical medical texts to isolate artemisinin, transforming the treatment of malaria.",
              researchTitles: ["Artemisinin", "Ancient Clues"]),
        .init(name: "Maryam Mirzakhani", slug: "maryam-mirzakhani", region: "Iran", field: "Mathematics",
              fact: "Her work connected the geometry and dynamics of curved surfaces; she became the first woman awarded a Fields Medal.",
              researchTitles: ["Geometry of Surfaces", "Moduli Spaces"]),
        .init(name: "Ahmed Zewail", slug: "ahmed-zewail", region: "Egypt", field: "Femtochemistry",
              fact: "He used ultrafast laser pulses to observe chemical bonds changing on the femtosecond timescale.",
              researchTitles: ["Femtosecond Chemistry", "Molecular Motion"]),
        .init(name: "Katherine Johnson", slug: "katherine-johnson", region: "United States", field: "Orbital mechanics",
              fact: "Her trajectory calculations supported the first US crewed spaceflights and the Apollo lunar missions.",
              researchTitles: ["Orbital Mechanics", "Lunar Trajectories"]),
        .init(name: "Hideki Yukawa", slug: "hideki-yukawa", region: "Japan", field: "Theoretical physics",
              fact: "He predicted the meson as the carrier of the nuclear force, years before a matching particle was observed.",
              researchTitles: ["Meson Theory", "Nuclear Forces"]),
        .init(name: "Wangari Maathai", slug: "wangari-maathai", region: "Kenya", field: "Biology and ecology",
              fact: "She founded the Green Belt Movement, joining ecological restoration with community leadership and human rights.",
              researchTitles: ["The Green Belt", "Restoration Ecology"]),
        .init(name: "Luis Federico Leloir", slug: "luis-leloir", region: "Argentina", field: "Biochemistry",
              fact: "He discovered sugar nucleotides and clarified how organisms manufacture and transform carbohydrates.",
              researchTitles: ["Sugar Nucleotides", "Carbohydrate Pathways"]),
        .init(name: "Chien-Shiung Wu", slug: "chien-shiung-wu", region: "China and United States", field: "Experimental physics",
              fact: "Her cobalt-60 experiment demonstrated that parity is not conserved in weak nuclear interactions.",
              researchTitles: ["The Wu Experiment", "Broken Symmetry"]),
        .init(name: "Abdus Salam", slug: "abdus-salam", region: "Pakistan", field: "Theoretical physics",
              fact: "His work helped unify electromagnetism and the weak nuclear force in the electroweak theory.",
              researchTitles: ["Unified Forces", "Electroweak Theory"]),
        .init(name: "Tebello Nyokong", slug: "tebello-nyokong", region: "South Africa", field: "Chemistry",
              fact: "She studies light-activated molecules for applications including cancer therapy and environmental sensing.",
              researchTitles: ["Molecular Light", "Photodynamic Chemistry"]),
        .init(name: "Mario Molina", slug: "mario-molina", region: "Mexico", field: "Atmospheric chemistry",
              fact: "He showed how chlorofluorocarbons damage stratospheric ozone, helping motivate a global environmental response.",
              researchTitles: ["The Ozone Shield", "Atmospheric Reactions"]),
        .init(name: "Alice Ball", slug: "alice-ball", region: "United States", field: "Chemistry",
              fact: "She developed an injectable form of chaulmoogra oil that became the leading treatment for Hansen’s disease of her era.",
              researchTitles: ["The Ball Method", "Medicinal Chemistry"]),
        .init(name: "Aziz Sancar", slug: "aziz-sancar", region: "Türkiye", field: "Molecular biology",
              fact: "He mapped the molecular machinery cells use to repair DNA damaged by ultraviolet light.",
              researchTitles: ["DNA Repair", "Molecular Clocks"]),
        .init(name: "Carlos Chagas", slug: "carlos-chagas", region: "Brazil", field: "Medicine and parasitology",
              fact: "He described a new disease together with its pathogen, insect vector, host, and clinical effects.",
              researchTitles: ["The Chagas Cycle", "Vector and Pathogen"]),
        .init(name: "Satyendra Nath Bose", slug: "satyendra-bose", region: "India", field: "Quantum physics",
              fact: "His new way of counting particles led to Bose–Einstein statistics and the name boson.",
              researchTitles: ["Quantum Statistics", "Bosonic Matter"]),
        .init(name: "Fe del Mundo", slug: "fe-del-mundo", region: "Philippines", field: "Pediatrics",
              fact: "She advanced child health research and founded the first pediatric hospital in the Philippines.",
              researchTitles: ["Child Health", "Rural Pediatrics"]),
        .init(name: "Ernest Rutherford", slug: "ernest-rutherford", region: "New Zealand", field: "Nuclear physics",
              fact: "The gold-foil experiment from his laboratory revealed that atoms contain a tiny, dense nucleus.",
              researchTitles: ["The Atomic Nucleus", "Gold Foil"]),
        .init(name: "Cecilia Payne-Gaposchkin", slug: "cecilia-payne", region: "United Kingdom and United States", field: "Astrophysics",
              fact: "She established that stars are composed mainly of hydrogen and helium, overturning the accepted view of her time.",
              researchTitles: ["Stellar Abundance", "Hydrogen Stars"]),
        .init(name: "Francis Allotey", slug: "francis-allotey", region: "Ghana", field: "Mathematical physics",
              fact: "He contributed to mathematical physics and built institutions that expanded advanced science education across Africa.",
              researchTitles: ["Mathematical Physics", "Scientific Foundations"]),
        .init(name: "Luis Miramontes", slug: "luis-miramontes", region: "Mexico", field: "Organic chemistry",
              fact: "At age 26, he co-synthesized norethisterone, a key active ingredient in the first oral contraceptives.",
              researchTitles: ["Norethisterone", "Molecular Synthesis"]),
        .init(name: "Subrahmanyan Chandrasekhar", slug: "chandrasekhar", region: "India and United States", field: "Astrophysics",
              fact: "He calculated the mass limit beyond which a white-dwarf star can no longer remain stable.",
              researchTitles: ["The Chandrasekhar Limit", "Stellar Evolution"]),
        .init(name: "Lise Meitner", slug: "lise-meitner", region: "Austria and Sweden", field: "Nuclear physics",
              fact: "She and Otto Frisch supplied the physical explanation and the name for nuclear fission.",
              researchTitles: ["Nuclear Fission", "Atomic Energy"]),
        .init(name: "Vera Rubin", slug: "vera-rubin", region: "United States", field: "Astronomy",
              fact: "Her measurements of galaxy rotation supplied compelling evidence for large amounts of unseen matter.",
              researchTitles: ["Galaxy Rotation", "Dark Matter Evidence"]),
        .init(name: "Dorothy Hodgkin", slug: "dorothy-hodgkin", region: "Egypt and United Kingdom", field: "Crystallography",
              fact: "She used X-ray crystallography to solve structures including penicillin, vitamin B12, and insulin.",
              researchTitles: ["Molecular Structures", "X-ray Crystallography"]),
        .init(name: "Howard Florey", slug: "howard-florey", region: "Australia", field: "Pathology",
              fact: "He led the team that turned penicillin from a laboratory observation into a practical medicine.",
              researchTitles: ["The Penicillin Path", "Antibiotic Medicine"]),
        .init(name: "Patricia Bath", slug: "patricia-bath", region: "United States", field: "Ophthalmology",
              fact: "She invented the Laserphaco Probe, improving the precision of cataract surgery.",
              researchTitles: ["Laserphaco", "Restoring Sight"]),
        .init(name: "Marie Curie", slug: "marie-curie", region: "Poland and France", field: "Physics and chemistry",
              fact: "Her research established radioactivity as an atomic property; she received Nobel Prizes in two scientific fields.",
              researchTitles: ["Radioactivity", "Radium and Polonium"]),
        .init(name: "Al-Khwarizmi", slug: "al-khwarizmi", region: "Khwarazm and Iraq", field: "Mathematics and astronomy",
              fact: "His systematic work on algebra shaped the discipline, and the word algorithm derives from his Latinized name.",
              researchTitles: ["The Algebra Treatise", "Algorithms"]),
        .init(name: "Hypatia", slug: "hypatia", region: "Egypt", field: "Mathematics and astronomy",
              fact: "She taught mathematics and astronomy in Alexandria and wrote influential commentaries on earlier mathematical works.",
              researchTitles: ["Alexandrian Mathematics", "Astronomical Tables"]),
        .init(name: "Ellen Ochoa", slug: "ellen-ochoa", region: "United States", field: "Optical engineering",
              fact: "Before becoming an astronaut, she co-invented optical systems for recognizing and inspecting patterns in images.",
              researchTitles: ["Optical Systems", "Pattern Recognition"]),
        .init(name: "Ada Lovelace", slug: "ada-lovelace", region: "United Kingdom", field: "Computing",
              fact: "Her notes on the Analytical Engine described a method for calculating Bernoulli numbers and imagined machines manipulating symbols.",
              researchTitles: ["The Analytical Engine", "Symbolic Machines"]),
        .init(name: "Grace Hopper", slug: "grace-hopper", region: "United States", field: "Computer science",
              fact: "She helped create early compilers and championed programming languages that read more like human language.",
              researchTitles: ["Compiler Languages", "Machine-independent Code"]),
    ]

    public static func matching(nameOrSlug value: String) -> ResearchIdentity? {
        let normalized = slugify(value)
        return catalog.first { $0.name.caseInsensitiveCompare(value) == .orderedSame || $0.slug == normalized }
    }

    public static func matching(researchTitle value: String) -> ResearchIdentity? {
        catalog.first { identity in
            identity.researchTitles.contains {
                $0.caseInsensitiveCompare(value) == .orderedSame
            }
        }
    }

    public static func next(excluding usedValues: Set<String>) -> ResearchIdentity {
        let normalized = Set(usedValues.map(slugify))
        return catalog.first { !normalized.contains($0.slug) }
            ?? catalog[normalized.count % catalog.count]
    }

    public static func nextResearchTitle(excluding usedTitles: Set<String>, preferred: ResearchIdentity? = nil) -> String {
        let used = Set(usedTitles.map { $0.lowercased() })
        let ordered = (preferred?.researchTitles ?? []) + catalog.flatMap(\.researchTitles)
        if let title = ordered.first(where: { !used.contains($0.lowercased()) }) { return title }
        var number = 2
        while used.contains("open question \(number)") { number += 1 }
        return "Open Question \(number)"
    }

    /// A concise, useful title for the first prompt in a workspace or chat.
    public static func taskTitle(from prompt: String, fallback: String = "New Inquiry") -> String {
        var words = prompt
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let disposable = Set(["please", "can", "could", "would", "you", "help", "me", "to", "the"])
        while let first = words.first,
              disposable.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        if let first = words.first?.lowercased().trimmingCharacters(in: .punctuationCharacters),
           ["build", "create", "implement", "fix", "review", "analyze", "analyse", "investigate", "update", "add"].contains(first),
           words.count > 2 {
            // Keep a useful action in titles like “Fix login race”, but drop
            // generic wrappers such as “Please help me to…”.
            words[0] = first.capitalized
        }
        let joined = words.prefix(7).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
        guard !joined.isEmpty else { return fallback }
        let clipped = joined.count > 46 ? String(joined.prefix(45)).trimmingCharacters(in: .whitespaces) + "…" : joined
        return clipped.prefix(1).uppercased() + clipped.dropFirst()
    }

    public static func unique(_ proposed: String, excluding usedTitles: Set<String>) -> String {
        let lowered = Set(usedTitles.map { $0.lowercased() })
        guard lowered.contains(proposed.lowercased()) else { return proposed }
        var number = 2
        while lowered.contains("\(proposed.lowercased()) · \(number)") { number += 1 }
        return "\(proposed) · \(number)"
    }

    public static func slugify(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
    }
}
