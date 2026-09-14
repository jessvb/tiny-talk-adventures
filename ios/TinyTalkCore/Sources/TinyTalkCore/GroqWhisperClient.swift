import Foundation

func wavData(fromPCM16 pcm: Data, sampleRate: Int = 24_000, channels: Int = 1) -> Data {
    func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
    let byteRate = sampleRate * channels * 2
    let blockAlign = channels * 2
    var header = Data()
    header.append(contentsOf: "RIFF".utf8)
    header.append(contentsOf: littleEndianBytes(UInt32(36 + pcm.count)))
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    header.append(contentsOf: littleEndianBytes(UInt32(16)))
    header.append(contentsOf: littleEndianBytes(UInt16(1))) // PCM
    header.append(contentsOf: littleEndianBytes(UInt16(channels)))
    header.append(contentsOf: littleEndianBytes(UInt32(sampleRate)))
    header.append(contentsOf: littleEndianBytes(UInt32(byteRate)))
    header.append(contentsOf: littleEndianBytes(UInt16(blockAlign)))
    header.append(contentsOf: littleEndianBytes(UInt16(16))) // bits per sample
    header.append(contentsOf: "data".utf8)
    header.append(contentsOf: littleEndianBytes(UInt32(pcm.count)))
    return header + pcm
}

private struct GroqTranscriptionResponse: Decodable { let text: String }

/// SpeechTranscribing backed by Groq's OpenAI-compatible Whisper
/// transcription endpoint.
public final class GroqWhisperClient: SpeechTranscribing, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let host: String
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = "whisper-large-v3-turbo",
        host: String = "https://api.groq.com",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.host = host
        self.session = session
    }

    public func transcribe(_ pcm: Data) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "\(host)/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, wav: wavData(fromPCM16: pcm), model: model)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw DemoConnectionError.groqError("Groq transcription returned an error: \(detail)")
        }
        return try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data).text
    }

    private func multipartBody(boundary: String, wav: Data, model: String) -> Data {
        var body = Data()
        func appendUTF8(_ string: String) { body.append(Data(string.utf8)) }
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        appendUTF8("\(model)\r\n")
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\n")
        appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }
}
