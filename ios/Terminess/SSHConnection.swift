import Dispatch
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum SSHError: LocalizedError {
    case hostKeyChanged(String)
    case authenticationFailed
    case channel(String)

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged: return "This server's key has changed since you last connected. If you didn't reinstall it, someone may be intercepting the connection."
        case .authenticationFailed: return "The server didn't accept this iPhone's key. Add it to ~/.ssh/authorized_keys on the server."
        case .channel(let m): return m
        }
    }
}

final class SSHConnection: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.group = group
        self.channel = channel
    }

    static func connect(host: String, port: Int, user: String, key: NIOSSHPrivateKey,
                        knownHostKey: String?, onNewHostKey: @escaping (String) -> Void) async throws -> SSHConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let auth = KeyAuthentication(user: user, key: key)
        let hostCheck = HostKeyCheck(known: knownHostKey, onNew: onNewHostKey)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: hostCheck)),
                                            allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandlers([ssh, CloseOnError()])
                }
            }
        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            let conn = SSHConnection(group: group, channel: channel)
            let probe = try await conn.exec("true")
            close(probe)
            if let failure = hostCheck.failure { throw failure }
            return conn
        } catch {
            try? await group.shutdownGracefully()
            if let failure = hostCheck.failure { throw failure }
            if auth.offered && !(error is SSHError) { throw SSHError.authenticationFailed }
            throw error
        }
    }

    func exec(_ command: String) async throws -> Int32 {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw SSHError.channel("socketpair failed") }
        let local = fds[0], bridged = fds[1]
        let loop = channel.eventLoop
        let promise = loop.makePromise(of: Channel.self)
        let channel = self.channel
        loop.execute {
            channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                switch result {
                case .failure(let error):
                    promise.fail(error)
                case .success(let ssh):
                    ssh.createChannel(promise, channelType: .session) { child, type in
                        guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.channel("unexpected channel type")) }
                        return child.eventLoop.makeCompletedFuture {
                            try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                            try child.pipeline.syncOperations.addHandler(ExecBridge(command: command, fd: bridged))
                        }
                    }
                }
            }
        }
        do {
            _ = try await withTimeout(seconds: 15) { try await promise.futureResult.get() }
        } catch {
            close(local)
            close(bridged)
            throw error
        }
        return local
    }

    func disconnect() {
        channel.close(promise: nil)
        group.shutdownGracefully { _ in }
    }
}

private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await body() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SSHError.channel("timed out")
        }
        let first = try await g.next()!
        g.cancelAll()
        return first
    }
}

private final class KeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let user: String
    let key: NIOSSHPrivateKey
    var offered = false

    init(user: String, key: NIOSSHPrivateKey) {
        self.user = user
        self.key = key
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "",
                                                                   offer: .privateKey(.init(privateKey: key))))
    }
}

private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let known: String?
    let onNew: (String) -> Void
    var failure: SSHError?

    init(known: String?, onNew: @escaping (String) -> Void) {
        self.known = known
        self.onNew = onNew
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let seen = String(openSSHPublicKey: hostKey)
        if let known, known != seen {
            failure = .hostKeyChanged(seen)
            validationCompletePromise.fail(failure!)
            return
        }
        if known == nil { onNew(seen) }
        validationCompletePromise.succeed(())
    }
}

private final class CloseOnError: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class ExecBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    let command: String
    let fd: Int32
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "ssh.bridge")

    init(command: String, fd: Int32) {
        self.command = command
        self.fd = fd
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false), promise: nil)
        let loop = context.eventLoop
        let channel = context.channel
        let fd = self.fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        src.setEventHandler { [weak src] in
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                let bytes = Array(buf[0..<n])
                loop.execute {
                    var bb = channel.allocator.buffer(capacity: bytes.count)
                    bb.writeBytes(bytes)
                    channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bb)), promise: nil)
                }
            } else {
                src?.cancel()
                loop.execute { channel.close(promise: nil) }
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(let bb) = d.data, d.type == .channel, let bytes = bb.getBytes(at: bb.readerIndex, length: bb.readableBytes) else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n } else if errno != EINTR && errno != EAGAIN { break }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let source { source.cancel() } else { close(fd) }
        source = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
