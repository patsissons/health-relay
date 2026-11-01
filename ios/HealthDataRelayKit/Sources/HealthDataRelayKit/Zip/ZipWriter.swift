import Compression
import Foundation

/// Writes a ZIP file, streaming each entry through DEFLATE so its size costs no
/// memory. Entries past 4 GB, or files of more than 65,534 entries, would need
/// ZIP64 and are refused: an export that large has other problems first.
public final class ZipWriter {
    public enum Failure: Error, Equatable {
        case tooLarge
        case compression
    }

    private struct Entry {
        let name: Data
        let crc: UInt32
        let compressed: UInt32
        let size: UInt32
        let offset: UInt32
        let time: UInt16
        let date: UInt16
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []

    /// A buffer's worth at a time.
    private static let chunk = 1 << 16

    public init(url: URL, attributes: [FileAttributeKey: Any]? = nil) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
        if offset > UInt64(UInt32.max) { throw Failure.tooLarge }
    }

    /// Adds a file. Its name is flattened so it can't unpack outside the folder.
    public func add(file: URL, name: String, date: Date = Date()) throws {
        guard entries.count < 65_534 else { throw Failure.tooLarge }
        let safe = name.replacingOccurrences(of: "\\", with: "-").split(separator: "/").joined(separator: "-")
        let nameData = Data((safe.isEmpty ? "file" : safe).utf8)
        let (dosTime, dosDate) = Self.dos(date)
        let start = offset
        var header = Data()
        header.le32(0x0403_4B50)
        header.le16(20) // version needed
        header.le16(0x0808) // sizes in a trailing descriptor, UTF-8 name
        header.le16(8) // deflate
        header.le16(dosTime)
        header.le16(dosDate)
        header.le32(0)
        header.le32(0)
        header.le32(0)
        header.le16(UInt16(nameData.count))
        header.le16(0)
        header.append(nameData)
        try write(header)

        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var crc = CRC32()
        var size: UInt64 = 0
        var compressed: UInt64 = 0

        let bufferOut = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { bufferOut.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.compression }
        defer { compression_stream_destroy(streamPointer) }
        streamPointer.pointee.dst_ptr = bufferOut
        streamPointer.pointee.dst_size = Self.chunk
        streamPointer.pointee.src_size = 0

        var finished = false
        while !finished {
            try autoreleasepool {
                let input = try reader.read(upToCount: Self.chunk) ?? Data()
                let last = input.isEmpty
                crc.add(input)
                size += UInt64(input.count)
                try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                        streamPointer.pointee.src_ptr = base
                    } else {
                        streamPointer.pointee.src_ptr = UnsafePointer(bufferOut)
                    }
                    streamPointer.pointee.src_size = raw.count
                    repeat {
                        let status = compression_stream_process(streamPointer, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                        guard status != COMPRESSION_STATUS_ERROR else { throw Failure.compression }
                        let produced = Self.chunk - streamPointer.pointee.dst_size
                        if produced > 0 && (streamPointer.pointee.dst_size == 0 || status == COMPRESSION_STATUS_END) {
                            try write(Data(bytes: bufferOut, count: produced))
                            compressed += UInt64(produced)
                            streamPointer.pointee.dst_ptr = bufferOut
                            streamPointer.pointee.dst_size = Self.chunk
                        }
                        if status == COMPRESSION_STATUS_END { finished = true }
                    } while streamPointer.pointee.src_size > 0 || (last && !finished)
                }
            }
        }
        guard size <= UInt64(UInt32.max), compressed <= UInt64(UInt32.max) else { throw Failure.tooLarge }

        var descriptor = Data()
        descriptor.le32(0x0807_4B50)
        descriptor.le32(crc.value)
        descriptor.le32(UInt32(compressed))
        descriptor.le32(UInt32(size))
        try write(descriptor)
        entries.append(Entry(name: nameData, crc: crc.value, compressed: UInt32(compressed), size: UInt32(size), offset: UInt32(start), time: dosTime, date: dosDate))
    }

    /// Writes the directory. The file isn't a valid ZIP until this runs.
    public func finish() throws {
        let start = offset
        for e in entries {
            var c = Data()
            c.le32(0x0201_4B50)
            c.le16(20)
            c.le16(20)
            c.le16(0x0808)
            c.le16(8)
            c.le16(e.time)
            c.le16(e.date)
            c.le32(e.crc)
            c.le32(e.compressed)
            c.le32(e.size)
            c.le16(UInt16(e.name.count))
            c.le16(0)
            c.le16(0)
            c.le16(0)
            c.le16(0)
            c.le32(0)
            c.le32(e.offset)
            c.append(e.name)
            try write(c)
        }
        var end = Data()
        end.le32(0x0605_4B50)
        end.le16(0)
        end.le16(0)
        end.le16(UInt16(entries.count))
        end.le16(UInt16(entries.count))
        end.le32(UInt32(offset - start))
        end.le32(UInt32(start))
        end.le16(0)
        try write(end)
        try handle.close()
    }

    /// DOS time and date, in UTC, the most a ZIP's basic fields can say.
    private static func dos(_ date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = (c.hour! << 11) | (c.minute! << 5) | (c.second! / 2)
        let day = (max(c.year! - 1980, 0) << 9) | (c.month! << 5) | c.day!
        return (UInt16(time), UInt16(day))
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func le32(_ v: UInt32) {
        le16(UInt16(v & 0xFFFF))
        le16(UInt16(v >> 16))
    }
}

/// CRC-32 as ZIP uses it.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func add(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for b in raw { state = Self.table[Int((state ^ UInt32(b)) & 0xFF)] ^ (state >> 8) }
        }
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}
