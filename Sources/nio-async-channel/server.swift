import NIOCore
import NIOHTTP1
import NIOPosix

struct Request: Sendable {
    let head: HTTPRequestHead
    let body: ByteBuffer?
}

struct Response: Sendable {
    struct Body {
        public let contentLength: Int?
        public let write: @Sendable (ResponseBodyWriter) async throws -> Void

        public init(contentLength: Int? = nil, _ write: @Sendable @escaping (ResponseBodyWriter) async throws -> Void) {
            self.write = write
            self.contentLength = contentLength
        }

        /// Initialise empty HBResponseBody
        public init() {
            self.init(contentLength: 0) { _ in }
        }

        /// Initialise Response.Body that contains a single ByteBuffer
        public init(byteBuffer: ByteBuffer) {
            self.init(contentLength: byteBuffer.readableBytes) { writer in try await writer.write(byteBuffer) }
        }

        /// Initialise Response.Body that contains a single String
        public init(string: String) {
            let byteBuffer = ByteBuffer(string: string)
            self.init(contentLength: byteBuffer.readableBytes) { writer in try await writer.write(byteBuffer) }
        }
    }

    public init(head: HTTPResponseHead, body: Body = .init()) {
        self.head = head
        self.body = body
        if let contentLength = body.contentLength {
            self.head.headers.replaceOrAdd(name: "content-length", value: String(describing: contentLength))
        }
    }

    var head: HTTPResponseHead
    let body: Body
}

protocol HTTPResponder: Sendable {
    func respond(_ request: Request) async throws -> Response
}

struct ResponseBodyWriter {
    /// The components of a HTTP response from the view of a HTTP server.
    public typealias OutboundWriter = NIOAsyncChannelOutboundWriter<SendableHTTPServerResponsePart>

    let outbound: OutboundWriter

    func write(_ buffer: ByteBuffer) async throws {
        try await self.outbound.write(.body(buffer))
    }
}

final class HTTPServer<Responder: HTTPResponder>: Sendable {
    typealias ChildChannel = NIOAsyncChannel<HTTPServerRequestPart, SendableHTTPServerResponsePart>
    typealias ServerChannel = NIOAsyncChannel<ChildChannel, Never>

    let responder: Responder
    let eventLoopGroup: any EventLoopGroup

    public init(
        responder: Responder,
        eventLoopGroup: any EventLoopGroup // TODO: We probably want to take a universal server bootstrap here
    ) {
        self.responder = responder
        self.eventLoopGroup = eventLoopGroup
    }

    public func run() async throws {
        let port = 8081
        let channel = try await ServerBootstrap(group: eventLoopGroup)
            .bind(host: "127.0.0.1", port: port) { channel in
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(HTTPSendableResponseChannelHandler())
                }.flatMapThrowing { _ in
                    try NIOAsyncChannel(
                        synchronouslyWrapping: channel,
                        configuration: .init(
                            inboundType: HTTPServerRequestPart.self,
                            outboundType: SendableHTTPServerResponsePart.self
                        )
                    )
                }
            }
        print("Server running on port: \(port)")

        try await self.handleServerChannel(channel, responder: responder)
    }

    private func handleServerChannel(
        _ serverChannel: ServerChannel,
        responder: Responder
    ) async throws {
        await withDiscardingTaskGroup { group in
            do {
                for try await childChannel in serverChannel.inbound {
                    group.addTask {
                        await self.handleHTTPRequestChannel(childChannel, responder: responder)
                    }
                }
            } catch {
                fatalError()
            }
        }
    }

    private func handleHTTPRequestChannel(
        _ channel: ChildChannel,
        responder: Responder
    ) async {
        do {
            var iterator = channel.inbound.makeAsyncIterator()
            let responseBodyWriter = ResponseBodyWriter(outbound: channel.outbound)
            while let part = try await iterator.next() {
                guard case .head(let head) = part else {
                    fatalError()
                }
                var body: ByteBuffer?
                if case .body(var buffer) =  try await iterator.next() {
                    while case .body(var part) = try await iterator.next() {
                        buffer.writeBuffer(&part)
                    }
                    body = buffer
                }

                let request = Request(head: head, body: body)
                let response: Response
                do {
                    response = try await responder.respond(request)
                } catch {
                    let head = HTTPResponseHead(version: .http1_1, status: .internalServerError)
                    response = Response(head: head, body: .init(string: "\(error)"))
                }

                try await channel.outbound.write(.head(response.head))
                try await response.body.write(responseBodyWriter)
                try await channel.outbound.write(.end(nil))
            }
        } catch {
            print(error)
        }
    }
}

struct HelloResponder: HTTPResponder {
    func respond(_ request: Request) async -> Response {
        let head = HTTPResponseHead(
            version: .http1_1, 
            status: .ok, 
            headers: ["server": "TestServer"]
        )
        return Response(head: head, body: .init(string: "Hello"))
    }
}

@main
struct NIOAsyncChannelServer {
    static func main() async throws {
        let server = HTTPServer(responder: HelloResponder(), eventLoopGroup: MultiThreadedEventLoopGroup.singleton)
        try await server.run()
    }
}

