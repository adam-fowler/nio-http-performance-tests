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
        public let write: @Sendable (ResponseBodyWriter) -> Void

        public init(contentLength: Int? = nil, _ write: @Sendable @escaping (ResponseBodyWriter) -> Void) {
            self.write = write
            self.contentLength = contentLength
        }

        /// Initialise empty HBResponseBody
        public init() {
            self.init(contentLength: 0) { _ in }
        }

        /// Initialise Response.Body that contains a single ByteBuffer
        public init(byteBuffer: ByteBuffer) {
            self.init(contentLength: byteBuffer.readableBytes) { writer in writer.write(byteBuffer) }
        }

        /// Initialise Response.Body that contains a single String
        public init(string: String) {
            let byteBuffer = ByteBuffer(string: string)
            self.init(contentLength: byteBuffer.readableBytes) { writer in writer.write(byteBuffer) }
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
    func respond(_ request: Request, eventLoop: EventLoop) -> EventLoopFuture<Response>
}

struct ResponseBodyWriter {
    let context: ChannelHandlerContext

    func write(_ buffer: ByteBuffer) {
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
    }
}

final class HTTPServer<Responder: HTTPResponder>: Sendable {
    let responder: Responder
    let eventLoopGroup: any EventLoopGroup

    public init(
        responder: Responder,
        eventLoopGroup: any EventLoopGroup // TODO: We probably want to take a universal server bootstrap here
    ) {
        self.responder = responder
        self.eventLoopGroup = eventLoopGroup
    }

    public func run() throws {
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .childChannelInitializer { channel in
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(HTTPServerChannel(self.responder))
                }
            }
        do {
            let port = 8081
            let channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
            print("Server running on port: \(port)")
            try channel.closeFuture.wait()
        } catch {
            print("\(error)")
        }
    }
}

final class HTTPServerChannel<Responder: HTTPResponder>: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = Never
    typealias OutboundOut = HTTPServerResponsePart

    enum State {
        case idle
        case head(HTTPRequestHead)
        case body(HTTPRequestHead, ByteBuffer)
    }
    var state: State = .idle
    let responder: Responder

    init(_ responder: Responder) {
        self.responder = responder
    }

    /// Read HTTP parts and convert into HBHTTPRequest and send to `readRequest`
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)

        switch (part, self.state) {
        case (.head(let head), .idle):
            self.state = .head(head)

        case (.end, .head(let head)):
            let request = Request(head: head, body: nil)
            handleRequest(request, context: context)
            self.state = .idle

        case (.body(let part), .head(let head)):
            self.state = .body(head, part)

        case (.end, .body(let head, let buffer)):
            let request = Request(head: head, body: buffer)
            handleRequest(request, context: context)
            self.state = .idle

        case (.body(var part), .body(let head, var buffer)):
            buffer.writeBuffer(&part)
            self.state = .body(head, buffer)

        default:
            assertionFailure("Should not get here!\nPart: \(part)\nState: \(self.state)")
            context.close(promise: nil)
        }
    }

    func handleRequest(_ request: Request, context: ChannelHandlerContext) {
        self.responder.respond(request, eventLoop: context.eventLoop).whenComplete { result in
            let response: Response
            switch result {
            case .success(let successfulResponse):
                response = successfulResponse
            case .failure(let error):
                let head = HTTPResponseHead(version: .http1_1, status: .internalServerError)
                response = Response(head: head, body: .init(string: "\(error)"))
            }
            let responseBodyWriter = ResponseBodyWriter(context: context)
            context.write(self.wrapOutboundOut(.head(response.head)), promise: nil)
            response.body.write(responseBodyWriter)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

struct HelloResponder: HTTPResponder {
    func respond(_ request: Request, eventLoop: EventLoop) -> EventLoopFuture<Response> {
        let head = HTTPResponseHead(
            version: .http1_1, 
            status: .ok, 
            headers: ["server": "TestServer"]
        )
        let response = Response(head: head, body: .init(string: "Hello"))
        return eventLoop.makeSucceededFuture(response)
    }
}

@main
struct EventLoopServer {
    static func main() throws {
        let server = HTTPServer(responder: HelloResponder(), eventLoopGroup: MultiThreadedEventLoopGroup.singleton)
        try server.run()
    }
}
