import Foundation

/// Runs one template pipeline: renders what's due to disk, then delivers it
/// part by part. Retries send the rendered bytes, never a fresh read.
struct ArtifactRunner: Sendable {
    /// Moments the screens can show.
    enum Step: Equatable, Sendable {
        case rendering
        case sending(part: Int, of: Int)
    }

    let files: FileStore
    let store: HealthQuerying
    let calendar: Calendar
    let now: @Sendable () -> Date
    let pause: @Sendable (Duration) async -> Void
    let export: @Sendable () -> ExportInfo
    let limits: TemplateLimits

    /// The saved cursor: read and replace.
    struct CursorAccess: Sendable {
        let read: @Sendable () async -> ExtractCursor
        let write: @Sendable (ExtractCursor) async -> Void
    }

    func run(id: UUID, definition: PipelineDefinition, template: ParsedTemplate, destinationTemplate: String?, access: Pusher.LaneAccess, cursor: CursorAccess, answer: DateInterval?, transport: ArtifactTransport, progress: @Sendable (Step) async -> Void = { _ in }) async -> Pusher.Stop {
        files.clearUnfinishedArtifacts(id)
        var produced = false
        while true {
            if await access.shouldStop() { return .stopped }
            guard let lane = await access.read() else { return .done }
            if let artifact = files.artifacts(id).first {
                if let stop = await deliver(artifact, id: id, access: access, transport: transport, progress: progress) { return stop }
                // A run finishing what the last one started is a whole run:
                // a range read now would send its data twice.
                produced = true
                continue
            }
            if produced && !definition.usesDirtyDays { return .done }
            do {
                await progress(.rendering)
                guard try await produce(id: id, definition: definition, template: template, destinationTemplate: destinationTemplate, lane: lane, cursor: cursor, answer: answer, access: access) else { return .done }
                produced = true
            } catch let error as TemplateError {
                // A template doesn't get better by being retried.
                let message = error.description
                await access.update { lane in
                    lane.attention = message
                    lane.lastError = message
                }
                return .failed
            } catch RangePlanner.Failure.needsAnswer {
                await access.update { $0.lastError = "This pipeline asks for its range when you tap Run." }
                return .failed
            } catch {
                return .unreadable(error.localizedDescription)
            }
        }
    }

    /// Renders one artifact. False when there's nothing to send.
    private func produce(id: UUID, definition: PipelineDefinition, template: ParsedTemplate, destinationTemplate: String?, lane: Lane, cursor: CursorAccess, answer: DateInterval?, access: Pusher.LaneAccess) async throws -> Bool {
        let spec = definition.extract
        let at = now()
        let saved = await cursor.read()
        var nextAnchors: [HealthType: Data] = [:]
        var late: [DateInterval] = []
        var days: [Day] = []

        switch spec.range {
        case .changedDays:
            // Types outside the native catalog have no shared anchors, so this
            // pipeline watches them itself.
            let shared = Set(Catalog.allTypes)
            let own = spec.healthTypes.filter { !shared.contains($0) }
            let found = try await Extractor.late(in: store, types: own, cursor: ExtractCursor(lastEnd: .distantFuture, anchors: saved.anchors), since: at.addingTimeInterval(-40 * 86400))
            nextAnchors = found.anchors
            let extra = found.late.flatMap { DirtyRules.days(of: $0, calendar: calendar) }
            if !extra.isEmpty {
                await access.update { $0.dirty.mark(extra, at: at) }
            }
            let dirty = Set(lane.dirty.days).union(extra)
            days = dirty.filter { !lane.covered($0) || extra.contains($0) }.sorted()
            guard !days.isEmpty else {
                if !nextAnchors.isEmpty { await cursor.write(RangePlanner(calendar: calendar).advanced(saved, spec: spec.range, now: at, anchors: nextAnchors)) }
                return false
            }
        case .sinceLastRun:
            let found = try await Extractor.late(in: store, types: spec.healthTypes, cursor: saved, since: at.addingTimeInterval(-40 * 86400))
            late = found.late
            nextAnchors = found.anchors
        default:
            break
        }

        let ranges = try RangePlanner(calendar: calendar).ranges(spec.range, now: at, cursor: saved, changedDays: days, late: late, answer: answer)
        let extractor = Extractor(store: store, spec: spec, calendar: calendar, ranges: ranges)
        let folder = try files.beginArtifact(id)
        var counter = 0
        var names: [String] = []
        var sinks: [FileSink] = []
        do {
            let rendered = try await TemplateTransformer(template: template, limits: limits).run(extractor: extractor, export: export()) { _, _ in
                let name = "part-\(counter)"
                counter += 1
                names.append(name)
                let sink = try FileSink(url: folder.appendingPathComponent(name), attributes: FileStore.partAttributes)
                sinks.append(sink)
                return sink
            }
            for sink in sinks { try sink.close() }
            let rows = rendered.parts.reduce(0) { $0 + $1.rows }
            // Empty only counts for a range with nothing new: an empty changed
            // day still has to arrive, since that's how a deletion gets there.
            if rows == 0 && spec.range == .sinceLastRun {
                try? FileManager.default.removeItem(at: folder)
                await cursor.write(RangePlanner(calendar: calendar).advanced(saved, spec: spec.range, now: at, anchors: nextAnchors))
                return false
            }
            var parts: [ArtifactPart] = []
            for (i, part) in rendered.parts.enumerated() {
                let address = try await rendered.destination(i, destinationTemplate)
                parts.append(ArtifactPart(key: part.key, filename: part.filename, file: names[part.index], contentType: part.contentType, bytes: part.bytes, destination: address))
            }
            let artifact = Artifact(createdAt: at, days: days, rows: rows, parts: parts)
            try files.commitArtifact(artifact, from: folder, pipeline: id)
        } catch {
            for sink in sinks { try? sink.close() }
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        // Saved only once the artifact is safe on disk: a crash before here reads the range again.
        await cursor.write(RangePlanner(calendar: calendar).advanced(saved, spec: spec.range, now: at, anchors: nextAnchors))
        return true
    }

    /// Delivers what's left of an artifact. Nil when all of it went through.
    private func deliver(_ start: Artifact, id: UUID, access: Pusher.LaneAccess, transport: ArtifactTransport, progress: @Sendable (Step) async -> Void) async -> Pusher.Stop? {
        var artifact = start
        for i in artifact.parts.indices where !artifact.parts[i].delivered {
            if await access.shouldStop() { return .stopped }
            await progress(.sending(part: i + 1, of: artifact.parts.count))
            let part = artifact.parts[i]
            let delivery = await transport.deliver(part: part, file: files.partFile(part, artifact: artifact.id, pipeline: id), artifact: artifact)
            let at = now()
            let entry = LogEntry(at: at, days: artifact.days, delivery: delivery)
            switch delivery.verdict {
            case .accepted:
                artifact.parts[i].delivered = true
                files.updateArtifact(artifact, pipeline: id)
                await access.update { $0.record(entry) }
                if !artifact.isDelivered { await pause(Pusher.spacing) }
            case .authFailed:
                await access.update { lane in
                    lane.record(entry)
                    lane.attention = delivery.message
                    lane.lastError = delivery.message
                }
                return .failed
            case .rejected:
                // The same bytes would be refused again, and the rest of the
                // artifact is the same run: drop it and keep any days dirty.
                files.removeArtifact(artifact.id, pipeline: id)
                await access.update { lane in
                    lane.record(entry)
                    lane.lastError = delivery.message
                    lane.backOff(now: at)
                }
                return .failed
            case .retry:
                await access.update { lane in
                    lane.record(entry)
                    lane.lastError = delivery.message
                    lane.backOff(now: at)
                }
                return .failed
            }
        }
        files.removeArtifact(artifact.id, pipeline: id)
        let done = now()
        let covered = artifact
        await access.update { lane in
            lane.dirty.clear(covered.days, readAt: covered.createdAt)
            lane.succeeded(now: done)
        }
        return nil
    }
}
