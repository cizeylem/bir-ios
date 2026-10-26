import Foundation

/// Ham JSON satırı taşıyan, dosya destekli kuyruk. İçeriği yorumlamaz.
///
/// Dosya mantıksal sınırın (`maxEvents`, `maxBytes`) %10 üstüne kadar büyür ve aşılınca
/// tek seferde budanır: sınırda bekleyen çevrimdışı bir kuyruk her event'te dosyayı
/// baştan yazmasın. Dışarıya yalnız mantıksal görünüm (en yeni satırlar) çıkar.
final class EventQueue: Sendable {
    private let fileURL: URL
    private let directory: URL
    private let maxEvents: Int
    private let maxBytes: Int
    private let slackEvents: Int
    private let slackBytes: Int
    private let lock = NSLock()

    // Tüm değişken durum `lock` ile korunur; Swift 6 bunu kendi başına kanıtlayamaz.
    nonisolated(unsafe) private var lines: [String] = []
    /// `lines` içinde mantıksal görünümün başladığı indeks (öncesi budanmayı bekleyen taşma).
    nonisolated(unsafe) private var start = 0
    nonisolated(unsafe) private var logicalBytes = 0
    nonisolated(unsafe) private var overflowBytes = 0
    nonisolated(unsafe) private var dropped = 0

    init(directory: URL, maxEvents: Int, maxBytes: Int) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("queue.jsonl")
        self.maxEvents = max(1, maxEvents)
        self.maxBytes = max(1, maxBytes)
        self.slackEvents = max(1, maxEvents / 10)
        self.slackBytes = max(1, maxBytes / 10)
        load()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count - start
    }

    var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped + start
    }

    func peek(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard n > 0 else { return [] }
        return Array(lines[start...].prefix(n))
    }

    func append(_ line: String) {
        // Satır ayracı içeren metin dosyada iki kayda bölünürdü; geçerli JSON bunu içermez.
        guard !line.isEmpty, !line.contains("\n"), !line.contains("\r") else { return }
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        logicalBytes += size(line)
        trimLogical()
        if start >= slackEvents || overflowBytes >= slackBytes {
            rewrite()   // budama: tek seferde, atomik
        } else if !appendToDisk(line) {
            rewrite()   // dosya/dizin kaybolmuş olabilir; belleğin tamamından yeniden kur
        }
    }

    func removeFirst(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        guard n > 0 else { return }
        let toRemove = min(n, lines.count - start)
        guard toRemove > 0 else { return }
        // Önce görünmez taşmayı sayaca al, sonra gönderilenleri at (onlar "düşen" değil).
        dropped += start
        lines.removeFirst(start + toRemove)
        start = 0
        logicalBytes = lines.reduce(0) { $0 + size($1) }
        overflowBytes = 0
        rewrite()
    }

    // MARK: - İç

    private func size(_ line: String) -> Int { line.utf8.count + 1 }

    /// Mantıksal görünümü sınırlar içine çeker; çıkan satırlar `start` ile işaretlenir.
    private func trimLogical() {
        while start < lines.count,
              lines.count - start > maxEvents || logicalBytes > maxBytes {
            let s = size(lines[start])
            logicalBytes -= s
            overflowBytes += s
            start += 1
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            ensureDirectory()
            return
        }
        var text = String(decoding: data, as: UTF8.self)
        // Sonu satır sonuyla bitmeyen parça yarım yazılmıştır (güç kesintisi); atılır.
        var repaired = false
        if !text.hasSuffix("\n") {
            repaired = true
            if let idx = text.lastIndex(of: "\n") {
                text = String(text[...idx])
            } else {
                text = ""
            }
        }
        lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        logicalBytes = lines.reduce(0) { $0 + size($1) }
        trimLogical()
        if repaired || start > 0 { rewrite() }
    }

    @discardableResult
    private func ensureDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private func appendToDisk(_ line: String) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let handle = try? FileHandle(forWritingTo: fileURL) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    /// Mantıksal görünümü diske yazar ve belleği de ona indirger. Diske yazılamazsa kuyruk bellekte sürer.
    private func rewrite() {
        dropped += start
        lines.removeFirst(start)
        start = 0
        overflowBytes = 0
        guard ensureDirectory() else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        let body = lines.map { $0 + "\n" }.joined()
        do {
            try Data(body.utf8).write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
