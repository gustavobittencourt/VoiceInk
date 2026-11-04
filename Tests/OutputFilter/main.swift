import Foundation

if CommandLine.arguments.count == 3 && ["--corpus", "--corpus-json"].contains(CommandLine.arguments[1]) {
    let content = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
    var total = 0
    var changed = 0
    for line in content.split(whereSeparator: \.isNewline) {
        guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = row["id"] as? String,
              let original = row["base"] as? String else {
            fputs("Registro de corpus inválido\n", stderr)
            exit(2)
        }
        total += 1
        let filtered = TranscriptionOutputFilter.filter(original)
        if filtered != original {
            changed += 1
            if CommandLine.arguments[1] == "--corpus-json" {
                let data = try JSONSerialization.data(withJSONObject: ["id": id, "after": filtered])
                print(String(decoding: data, as: UTF8.self))
            } else {
                let before = original.replacingOccurrences(of: "\n", with: "\\n")
                let after = filtered.replacingOccurrences(of: "\n", with: "\\n")
                print("\(id) | \(before) | \(after)")
            }
        }
    }
    fputs("Corpus: \(total) trechos, \(changed) alterados\n", stderr)
    exit(0)
}

let cases: [(String, String, String)] = [
    ("long repetition", "Sim, sim, sim, sim, sim.", "Sim."),
    ("triple que", "Qual que que que serve?", "Qual que que serve?"),
    ("capitalized que", "Que QUE que funciona?", "Que que funciona?"),
    ("three other words", "No teste, vem, vem, vem, então pare.", "No teste, vem, vem, vem, então pare."),
    ("three accented words", "Hoje tá tá tá!", "Hoje tá tá tá!"),
    ("two que", "Diga por que que mudou.", "Diga por que que mudou."),
    ("four accented words", "não não não não", "não"),
    ("two identical words", "antes antes", "antes antes"),
    ("single-letter words", "a a a a mesa", "a mesa"),
    ("empty", "", ""),
    ("preserve final punctuation", "Sim! sim? sim… sim;", "Sim;"),
    ("preserve word boundaries", "casa casas casa casas", "casa casas casa casas"),
    ("separator is not punctuation", "sim: sim: sim: sim", "sim: sim: sim: sim"),
]
var failures = 0
for (name, input, expected) in cases {
    let actual = TranscriptionOutputFilter.filter(input)
    if actual != expected {
        failures += 1
        fputs("FAIL \(name): esperado \(expected.debugDescription), obtido \(actual.debugDescription)\n", stderr)
    }
}
print("\(cases.count - failures) aprovados, \(failures) falhas, \(cases.count) casos")
if failures != 0 { exit(1) }
