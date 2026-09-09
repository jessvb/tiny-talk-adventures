import Foundation

public struct AnimalRecordCharacteristics: Sendable {
    public let mostDistinctiveFeature: String?
    public let topSpeed: String?
    public let diet: String?
    public let habitat: String?
    public let slogan: String?
    public let color: String?
    public let groupBehavior: String?
    public let lifespan: String?

    public init(
        mostDistinctiveFeature: String?, topSpeed: String?, diet: String?, habitat: String?,
        slogan: String?, color: String?, groupBehavior: String?, lifespan: String?
    ) {
        self.mostDistinctiveFeature = mostDistinctiveFeature
        self.topSpeed = topSpeed
        self.diet = diet
        self.habitat = habitat
        self.slogan = slogan
        self.color = color
        self.groupBehavior = groupBehavior
        self.lifespan = lifespan
    }
}

/// Swift port of server/tinytalk/animal_facts.py's detection and
/// extraction logic (the network call and cache are AnimalFactsAPIClient
/// and AnimalFactTracker, Task 11 -- this file has no I/O).
public enum AnimalFacts {
    // TRANSCRIBED FROM animal_facts.py's _KNOWN_ANIMALS (all 232 entries)
    static let knownAnimals: [String: [String]] = [
        "fox": ["fox", "foxes"],
        "rabbit": ["rabbit", "rabbits", "bunny", "bunnies"],
        "ladybug": ["ladybug", "ladybugs", "ladybird", "ladybirds"],
        "elephant": ["elephant", "elephants"],
        "owl": ["owl", "owls"],
        "dolphin": ["dolphin", "dolphins"],
        "bear": ["bear", "bears"],
        "lion": ["lion", "lions"],
        "tiger": ["tiger", "tigers"],
        "wolf": ["wolf", "wolves"],
        "deer": ["deer", "deers", "fawn", "fawns"],
        "squirrel": ["squirrel", "squirrels"],
        "turtle": ["turtle", "turtles"],
        "frog": ["frog", "frogs"],
        "penguin": ["penguin", "penguins"],
        "dog": ["dog", "dogs", "puppy", "puppies"],
        "cat": ["cat", "cats", "kitten", "kittens"],
        "horse": ["horse", "horses", "pony", "ponies", "colt", "colts", "foal", "foals"],
        "duck": ["duck", "ducks", "duckling", "ducklings"],
        "butterfly": ["butterfly", "butterflies"],
        "bee": ["bee", "bees", "honeybee", "honeybees"],
        "giraffe": ["giraffe", "giraffes"],
        "monkey": ["monkey", "monkeys"],
        "whale": ["whale", "whales"],
        "shark": ["shark", "sharks"],
        "eagle": ["eagle", "eagles"],
        "aardvark": ["aardvark", "aardvarks"],
        "alligator": ["alligator", "alligators"],
        "alpaca": ["alpaca", "alpacas"],
        "anaconda": ["anaconda", "anacondas"],
        "angelfish": ["angelfish", "angelfishes"],
        "ant": ["ant", "ants"],
        "antelope": ["antelope", "antelopes"],
        "armadillo": ["armadillo", "armadillos"],
        "axolotl": ["axolotl", "axolotls"],
        "baboon": ["baboon", "baboons"],
        "badger": ["badger", "badgers"],
        "bandicoot": ["bandicoot", "bandicoots"],
        "barracuda": ["barracuda", "barracudas"],
        "bat": ["bat", "bats", "vampire bat", "vampire bats"],
        "beaver": ["beaver", "beavers"],
        "beetle": ["beetle", "beetles", "junebug", "junebugs"],
        "bilby": ["bilby", "bilbies"],
        "bison": ["bison", "bisons", "buffalo", "buffaloes", "buffalos"],
        "blue jay": ["blue jay", "blue jays"],
        "bluebird": ["bluebird", "bluebirds"],
        "boa constrictor": ["boa constrictor", "boa constrictors", "boa", "boas"],
        "bobcat": ["bobcat", "bobcats"],
        "budgie": ["budgie", "budgies", "budgerigar", "budgerigars"],
        "bullfrog": ["bullfrog", "bullfrogs"],
        "bumblebee": ["bumblebee", "bumblebees"],
        "caecilian": ["caecilian", "caecilians"],
        "caiman": ["caiman", "caimans"],
        "camel": ["camel", "camels"],
        "canary": ["canary", "canaries"],
        "cane toad": ["cane toad", "cane toads"],
        "capybara": ["capybara", "capybaras"],
        "cardinal": ["cardinal", "cardinals"],
        "caterpillar": ["caterpillar", "caterpillars"],
        "chameleon": ["chameleon", "chameleons"],
        "cheetah": ["cheetah", "cheetahs"],
        "chickadee": ["chickadee", "chickadees"],
        "chicken": ["chicken", "chickens", "hen", "hens", "rooster", "roosters"],
        "chimpanzee": ["chimpanzee", "chimpanzees", "chimp", "chimps"],
        "chinchilla": ["chinchilla", "chinchillas"],
        "chipmunk": ["chipmunk", "chipmunks"],
        "cicada": ["cicada", "cicadas"],
        "clam": ["clam", "clams"],
        "clownfish": ["clownfish", "clownfishes"],
        "cobra": ["cobra", "cobras"],
        "cockatoo": ["cockatoo", "cockatoos"],
        "cockroach": ["cockroach", "cockroaches"],
        "coral": ["coral", "corals"],
        "cougar": ["cougar", "cougars", "puma", "pumas", "mountain lion", "mountain lions"],
        "cow": ["cow", "cows", "bull", "bulls", "calf", "calves"],
        "coyote": ["coyote", "coyotes"],
        "crab": ["crab", "crabs"],
        "cricket": ["cricket", "crickets"],
        "crocodile": ["crocodile", "crocodiles"],
        "crow": ["crow", "crows"],
        "dingo": ["dingo", "dingos", "dingoes"],
        "donkey": ["donkey", "donkeys"],
        "dove": ["dove", "doves"],
        "dragonfly": ["dragonfly", "dragonflies"],
        "elk": ["elk", "elks"],
        "emu": ["emu", "emus"],
        "falcon": ["falcon", "falcons"],
        "fennec fox": ["fennec fox", "fennec foxes", "desert fox", "desert foxes"],
        "ferret": ["ferret", "ferrets"],
        "finch": ["finch", "finches"],
        "firefly": ["firefly", "fireflies"],
        "flea": ["flea", "fleas"],
        "flounder": ["flounder", "flounders"],
        "fly": ["fly", "flies", "fruit fly", "fruit flies"],
        "gazelle": ["gazelle", "gazelles"],
        "gecko": ["gecko", "geckos", "geckoes"],
        "gerbil": ["gerbil", "gerbils"],
        "gila monster": ["gila monster", "gila monsters"],
        "glass frog": ["glass frog", "glass frogs"],
        "goanna": ["goanna", "goannas"],
        "goat": ["goat", "goats"],
        "goldfish": ["goldfish", "goldfishes"],
        "goose": ["goose", "geese"],
        "gorilla": ["gorilla", "gorillas"],
        "grasshopper": ["grasshopper", "grasshoppers"],
        "groundhog": ["groundhog", "groundhogs", "woodchuck", "woodchucks"],
        "guinea pig": ["guinea pig", "guinea pigs"],
        "hamster": ["hamster", "hamsters"],
        "hawk": ["hawk", "hawks"],
        "hedgehog": ["hedgehog", "hedgehogs"],
        "hellbender": ["hellbender", "hellbenders"],
        "hippopotamus": ["hippopotamus", "hippopotamuses", "hippo", "hippos"],
        "horned lizard": ["horned lizard", "horned lizards"],
        "hummingbird": ["hummingbird", "hummingbirds"],
        "hyena": ["hyena", "hyenas"],
        "ibis": ["ibis", "ibises"],
        "iguana": ["iguana", "iguanas"],
        "impala": ["impala", "impalas"],
        "inchworm": ["inchworm", "inchworms"],
        "jaguar": ["jaguar", "jaguars"],
        "jellyfish": ["jellyfish", "jellyfishes"],
        "jerboa": ["jerboa", "jerboas"],
        "kangaroo": ["kangaroo", "kangaroos"],
        "kangaroo rat": ["kangaroo rat", "kangaroo rats"],
        "katydid": ["katydid", "katydids"],
        "koala": ["koala", "koalas"],
        "kookaburra": ["kookaburra", "kookaburras"],
        "leopard": ["leopard", "leopards"],
        "leopard frog": ["leopard frog", "leopard frogs"],
        "llama": ["llama", "llamas"],
        "lobster": ["lobster", "lobsters"],
        "lorikeet": ["lorikeet", "lorikeets"],
        "lynx": ["lynx", "lynxes"],
        "lyrebird": ["lyrebird", "lyrebirds"],
        "macaw": ["macaw", "macaws"],
        "manatee": ["manatee", "manatees"],
        "manta ray": ["manta ray", "manta rays"],
        "meerkat": ["meerkat", "meerkats"],
        "mole": ["mole", "moles"],
        "monitor lizard": ["monitor lizard", "monitor lizards"],
        "moose": ["moose", "mooses"],
        "mosquito": ["mosquito", "mosquitoes", "mosquitos"],
        "moth": ["moth", "moths"],
        "mouse": ["mouse", "mice"],
        "mudpuppy": ["mudpuppy", "mudpuppies"],
        "mule": ["mule", "mules"],
        "narwhal": ["narwhal", "narwhals"],
        "newt": ["newt", "newts", "eastern newt", "eastern newts"],
        "nightingale": ["nightingale", "nightingales"],
        "nudibranch": ["nudibranch", "nudibranchs", "nudibranches"],
        "numbat": ["numbat", "numbats"],
        "nutria": ["nutria", "nutrias"],
        "ocelot": ["ocelot", "ocelots"],
        "octopus": ["octopus", "octopuses", "octopi"],
        "okapi": ["okapi", "okapis"],
        "opossum": ["opossum", "opossums"],
        "orangutan": ["orangutan", "orangutans"],
        "ostrich": ["ostrich", "ostriches"],
        "otter": ["otter", "otters"],
        "oyster": ["oyster", "oysters"],
        "panda": ["panda", "pandas"],
        "panther": ["panther", "panthers"],
        "parrot": ["parrot", "parrots"],
        "peacock": ["peacock", "peacocks"],
        "peccary": ["peccary", "peccaries"],
        "pelican": ["pelican", "pelicans"],
        "pig": ["pig", "pigs", "piglet", "piglets"],
        "pigeon": ["pigeon", "pigeons"],
        "platypus": ["platypus", "platypuses"],
        "polar bear": ["polar bear", "polar bears"],
        "porcupine": ["porcupine", "porcupines"],
        "possum": ["possum", "possums"],
        "praying mantis": ["praying mantis", "praying mantises", "praying mantids"],
        "python": ["python", "pythons"],
        "quail": ["quail", "quails"],
        "quokka": ["quokka", "quokkas"],
        "quoll": ["quoll", "quolls"],
        "raccoon": ["raccoon", "raccoons"],
        "rat": ["rat", "rats"],
        "rattlesnake": ["rattlesnake", "rattlesnakes"],
        "reindeer": ["reindeer", "reindeers", "caribou", "caribous"],
        "rhinoceros": ["rhinoceros", "rhinoceroses", "rhino", "rhinos"],
        "robin": ["robin", "robins"],
        "salamander": ["salamander", "salamanders", "marbled salamander", "marbled salamanders"],
        "sand cat": ["sand cat", "sand cats"],
        "scorpion": ["scorpion", "scorpions"],
        "sea otter": ["sea otter", "sea otters"],
        "sea turtle": ["sea turtle", "sea turtles"],
        "sea urchin": ["sea urchin", "sea urchins", "urchin", "urchins"],
        "seagull": ["seagull", "seagulls", "gull", "gulls"],
        "seahorse": ["seahorse", "seahorses"],
        "seal": ["seal", "seals"],
        "sheep": ["sheep", "lamb", "lambs"],
        "shrimp": ["shrimp", "shrimps"],
        "sidewinder": ["sidewinder", "sidewinders", "sidewinder snake", "sidewinder snakes"],
        "skink": ["skink", "skinks"],
        "skunk": ["skunk", "skunks"],
        "sloth": ["sloth", "sloths"],
        "slug": ["slug", "slugs"],
        "snail": ["snail", "snails"],
        "sparrow": ["sparrow", "sparrows"],
        "squid": ["squid", "squids"],
        "starfish": ["starfish", "starfishes"],
        "starling": ["starling", "starlings"],
        "stingray": ["stingray", "stingrays"],
        "sugar glider": ["sugar glider", "sugar gliders"],
        "swan": ["swan", "swans"],
        "swordfish": ["swordfish", "swordfishes"],
        "tapir": ["tapir", "tapirs"],
        "tarantula": ["tarantula", "tarantulas"],
        "tasmanian devil": ["tasmanian devil", "tasmanian devils"],
        "termite": ["termite", "termites"],
        "toad": ["toad", "toads"],
        "tortoise": ["tortoise", "tortoises"],
        "toucan": ["toucan", "toucans"],
        "tree frog": ["tree frog", "tree frogs"],
        "turkey": ["turkey", "turkeys"],
        "viper": ["viper", "vipers"],
        "vulture": ["vulture", "vultures"],
        "wallaby": ["wallaby", "wallabies"],
        "walrus": ["walrus", "walruses"],
        "warthog": ["warthog", "warthogs"],
        "wasp": ["wasp", "wasps", "yellow jacket", "yellow jackets"],
        "weasel": ["weasel", "weasels"],
        "wild boar": ["wild boar", "wild boars", "boar", "boars"],
        "wolverine": ["wolverine", "wolverines"],
        "wombat": ["wombat", "wombats"],
        "wood frog": ["wood frog", "wood frogs"],
        "woodpecker": ["woodpecker", "woodpeckers"],
        "x-ray tetra": ["x-ray tetra", "x-ray tetras"],
        "yak": ["yak", "yaks"],
        "zebra": ["zebra", "zebras"],
    ]

    private static let patterns: [String: NSRegularExpression] = {
        var result: [String: NSRegularExpression] = [:]
        for (canonical, aliases) in knownAnimals {
            let escaped = aliases.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            result[canonical] = try? NSRegularExpression(pattern: "\\b(?:\(escaped))\\b", options: .caseInsensitive)
        }
        return result
    }()

    /// Multi-word aliases must be checked before single-word ones (see
    /// animal_facts.py's _DETECTION_ORDER) -- "sea turtle" must not
    /// resolve to the generic "turtle" entry.
    private static let detectionOrder: [String] = knownAnimals.keys.sorted { lhs, rhs in
        let lhsSpecificity = knownAnimals[lhs]!.map { $0.split(separator: " ").count }.max() ?? 1
        let rhsSpecificity = knownAnimals[rhs]!.map { $0.split(separator: " ").count }.max() ?? 1
        if lhsSpecificity != rhsSpecificity { return lhsSpecificity > rhsSpecificity }
        return lhs < rhs // stable, deterministic tiebreaker (Python relies on dict definition order instead)
    }

    public static func findNewAnimal(in transcript: String, excluding alreadyFacted: [String]) -> String? {
        let alreadyFactedSet = Set(alreadyFacted)
        for canonical in detectionOrder {
            if alreadyFactedSet.contains(canonical) { continue }
            guard let pattern = patterns[canonical] else { continue }
            let range = NSRange(transcript.startIndex..., in: transcript)
            if pattern.firstMatch(in: transcript, range: range) != nil {
                return canonical
            }
        }
        return nil
    }

    public static func extractFacts(from characteristics: AnimalRecordCharacteristics) -> [String] {
        var facts: [String] = []
        func addFact(_ value: String?, _ template: (String) -> String) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            let fact = template(value)
            if Safety.isSafe(fact) { facts.append(fact) }
        }
        addFact(characteristics.mostDistinctiveFeature) { "its most distinctive feature is \($0)" }
        addFact(characteristics.topSpeed) { "it can move as fast as \($0)" }
        addFact(characteristics.diet) { "its diet is \($0)" }
        addFact(characteristics.habitat) { "it lives in \($0)" }
        addFact(characteristics.slogan) { $0 }
        addFact(characteristics.color) { "its coloring is \($0)" }
        addFact(characteristics.groupBehavior) { "its group behavior is \($0)" }
        return facts
    }
}
