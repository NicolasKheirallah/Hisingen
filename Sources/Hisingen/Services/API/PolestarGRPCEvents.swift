import Foundation

struct PolestarGRPCResponseHead: Sendable {
    let httpStatus: Int?
    let metadata: [String: String]
}

struct PolestarGRPCFinalStatus: Equatable, Sendable {
    let code: Int
    let message: String?
    let metadata: [String: String]
}

enum PolestarGRPCResponsePart: Sendable {
    case headers(PolestarGRPCResponseHead)
    case message(Data)
    case status(PolestarGRPCFinalStatus)
}

enum PolestarGRPCReadCompletion: Equatable, Sendable {
    case terminalStatus
    case firstSnapshot
}

actor PolestarGRPCExchangeState {
    struct Snapshot: Sendable {
        var head: PolestarGRPCResponseHead?
        var firstMessage: Data?
        var lastMessage: Data?
        var status: PolestarGRPCFinalStatus?
        var messageCount = 0
        var grpcCode: String? {
            status.map { String($0.code) } ?? head?.metadata["grpc-status"]
        }
        var grpcMessage: String? { status?.message ?? head?.metadata["grpc-message"] }
    }

    private var state = Snapshot()
    private let maximumMessages: Int?

    init(maximumMessages: Int? = 32) {
        self.maximumMessages = maximumMessages
    }

    func record(_ part: PolestarGRPCResponsePart) throws {
        guard state.status == nil else {
            throw PolestarError.invalidResponse(operation: "gRPC data after final status")
        }
        switch part {
        case .headers(let head):
            guard state.head == nil else {
                throw PolestarError.invalidResponse(operation: "duplicate gRPC response headers")
            }
            state.head = head
        case .message(let message):
            guard message.count <= GRPCFrameReader.maxFrameBytes else {
                throw PolestarError.responseTooLarge(operation: "gRPC message")
            }
            state.messageCount += 1
            guard maximumMessages.map({ state.messageCount <= $0 }) ?? true else {
                throw PolestarError.responseTooLarge(operation: "gRPC response message count")
            }
            if !message.isEmpty {
                if state.firstMessage == nil { state.firstMessage = message }
                state.lastMessage = message
            }
        case .status(let status):
            state.status = status
        }
    }

    func snapshot() -> Snapshot { state }
}
