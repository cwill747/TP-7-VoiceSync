import SwiftData
import Foundation

@Model
final class Person {
    @Attribute(.unique) var id: String
    var name: String
    var createdAt: Date
    var isSelf: Bool
    /// Mean of all enrolled sample embeddings. Empty until at least one sample is added.
    var embedding: [Float]
    @Relationship(deleteRule: .cascade) var samples: [VoiceSample]

    init(name: String, isSelf: Bool = false, embedding: [Float] = []) {
        self.id = UUID().uuidString
        self.name = name
        self.isSelf = isSelf
        self.embedding = embedding
        self.createdAt = Date()
        self.samples = []
    }

    var isEnrolled: Bool { !embedding.isEmpty }

    /// Recomputes the aggregate embedding as the element-wise mean of all sample embeddings.
    func recomputeEmbedding() {
        let validSamples = samples.filter { !$0.embedding.isEmpty }
        guard !validSamples.isEmpty else {
            embedding = []
            return
        }
        let dim = validSamples[0].embedding.count
        guard dim > 0 else { return }

        var sum = [Float](repeating: 0, count: dim)
        for sample in validSamples {
            guard sample.embedding.count == dim else { continue }
            for i in 0..<dim {
                sum[i] += sample.embedding[i]
            }
        }
        let count = Float(validSamples.count)
        embedding = sum.map { $0 / count }
    }
}
