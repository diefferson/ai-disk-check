import Foundation

func projectTechnologies(at root: String) -> [String] {
    func has(_ file: String) -> Bool { fm.fileExists(atPath: root + "/" + file) }
    var names = [String]()
    if has("pubspec.yaml"), let handle = FileHandle(forReadingAtPath:root + "/pubspec.yaml") {
        defer { try? handle.close() }
        if let data = try? handle.read(upToCount:128 * 1024),
           String(decoding:data,as:UTF8.self).range(of:#"(?m)^\s*sdk:\s*flutter\s*(?:#.*)?$"#,options:.regularExpression) != nil {
            names.append("Flutter")
        }
    }
    if ["app/src/main/AndroidManifest.xml","src/main/AndroidManifest.xml","android/app/src/main/AndroidManifest.xml","android/src/main/AndroidManifest.xml"].contains(where:has) { names.append("Android") }
    if ["pyproject.toml","requirements.txt","setup.py","Pipfile"].contains(where:has) { names.append("Python") }
    if has("Package.swift") { names.append("Swift") }
    if has("Cargo.toml") { names.append("Rust") }
    if has("package.json") { names.append("Node.js") }
    return names
}
