import Foundation
import NIOCore
import NIOPosix
import NIOHTTP2
import NIOHPACK

final class PolestarHTTP2TestServer: @unchecked Sendable {
    enum Reply: Sendable {
        case success, failure, trailersOnly, missing, malformed, reset, truncated, hang
        /// A complete reply message, then silence: no trailers and no end of stream, which is how
        /// the climate and charge-target commands behave on the real backend.
        case replyThenHang
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private let lock = NSLock()
    private var requests = 0
    let reply: Reply

    init(reply: Reply) { self.reply = reply }

    var requestCount: Int { lock.withLock { requests } }
    private func recordRequest() { lock.withLock { requests += 1 } }

    func start() throws -> Int {
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.configureHTTP2Pipeline(mode: .server) { stream in
                    stream.pipeline.addHandler(Handler(server: self))
                }.map { _ in () }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        self.channel = channel
        return channel.localAddress!.port!
    }

    func stop() throws {
        try channel?.close().wait()
        try group.syncShutdownGracefully()
    }

    /// Touched only from its channel's event loop, so the unchecked conformance is safe.
    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTP2Frame.FramePayload
        typealias OutboundOut = HTTP2Frame.FramePayload
        private let server: PolestarHTTP2TestServer
        private var sent = false
        init(server: PolestarHTTP2TestServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            let ended: Bool
            switch frame {
            case .headers(let headers): ended = headers.endStream
            case .data(let data): ended = data.endStream
            default: ended = false
            }
            guard ended, !sent else { return }
            sent = true
            server.recordRequest()
            guard server.reply != .hang else { return }
            if server.reply == .reset {
                context.writeAndFlush(wrapOutboundOut(.rstStream(.cancel)), promise: nil)
                return
            }
            var headers = HPACKHeaders([ (":status", "200"), ("content-type", "application/grpc") ])
            if server.reply == .trailersOnly {
                headers.add(name: "grpc-status", value: "7")
                headers.add(name: "grpc-message", value: "permission%20denied")
                headers.add(name: "fixture", value: "only")
                context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: headers, endStream: true))), promise: nil)
                return
            }
            context.write(wrapOutboundOut(.headers(.init(headers: headers))), promise: nil)
            if server.reply == .truncated {
                var partial = context.channel.allocator.buffer(capacity: 6)
                partial.writeBytes([0, 0, 0, 0, 3, 42])
                context.writeAndFlush(wrapOutboundOut(.data(.init(data: .byteBuffer(partial), endStream: true))), promise: nil)
                return
            }
            var buffer = context.channel.allocator.buffer(capacity: 6)
            buffer.writeBytes([0, 0, 0, 0, 1, 42])
            context.write(wrapOutboundOut(.data(.init(data: .byteBuffer(buffer)))), promise: nil)
            if server.reply == .replyThenHang {
                context.flush()
                return
            }
            var trailers = HPACKHeaders()
            switch server.reply {
            case .success: trailers.add(name: "grpc-status", value: "0")
            case .failure:
                trailers.add(name: "grpc-status", value: "7")
                trailers.add(name: "grpc-message", value: "permission%20denied")
            case .malformed: trailers.add(name: "grpc-status", value: "invalid")
            default: break
            }
            trailers.add(name: "fixture", value: "actual-trailer")
            context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: trailers, endStream: true))), promise: nil)
        }
    }
}
