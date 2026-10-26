import Compression
import Foundation

/// gzip zarfı (RFC 1952), elle kurulur: `Compression` framework'ü `COMPRESSION_ZLIB` ile zarfsız,
/// ham deflate üretir; sunucu `Content-Encoding: gzip` bekler. zlib'in `crc32` sembolü SPM'de
/// taşınabilir olmadığından CRC-32 tablosu da burada hesaplanır.
enum Gzip {
    /// `1f 8b` sihir, `08` deflate, `00` bayrak yok, 4 bayt mtime, XFL, OS.
    /// mtime bilerek sıfır: gerçek zaman yazmak aynı gövde için farklı bayt üretir ve testleri
    /// belirsizleştirir; gzip alıcıları sıfırı "zaman yok" diye kabul eder. OS `ff` = bilinmiyor.
    private static let header: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff]

    /// Boş girdinin deflate karşılığı (tek, son, boş sabit blok). Framework'ün boş girdideki
    /// davranışı belgelenmemiş (0 dönerse "hata"dan ayırt edilemez); sonuç sürüme bağlı kalmasın
    /// diye boş girdi sabit baytlarla ele alınır.
    private static let emptyDeflate: [UInt8] = [0x03, 0x00]

    /// Başarısızlıkta `nil` döner, fırlatmaz: sıkıştırmasız göndermeye çağıran karar verir.
    static func compress(_ data: Data) -> Data? {
        var out = Data(header)
        if data.isEmpty {
            out.append(contentsOf: emptyDeflate)
        } else {
            guard let deflated = deflate(data) else { return nil }
            out.append(deflated)
        }
        appendLE32(&out, crc32(data))
        // ISIZE modulo 2^32'dir (RFC 1952); 4 GB üstü girdide dönüşüm çökmesin.
        appendLE32(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// `capacity` yalnız testler içindir: tampon yetmezse `nil` dönmesi başka türlü sınanamaz.
    static func deflate(_ data: Data, capacity override: Int? = nil) -> Data? {
        // Sıkıştırılamayan veri deflate'te biraz büyür (saklı blok başına 5 bayt); hedef tampon
        // yetmezse `compression_encode_buffer` 0 döner. 0'ı bayt sayısı sanıp boş akış yazmak
        // yerine hata sayılır.
        let capacity = override ?? data.count + data.count / 8 + 1024
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&dst, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(dst[0..<written])
    }

    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(truncatingIfNeeded: v))
        d.append(UInt8(truncatingIfNeeded: v >> 8))
        d.append(UInt8(truncatingIfNeeded: v >> 16))
        d.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
