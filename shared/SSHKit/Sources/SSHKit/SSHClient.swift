// One SSH connection: connect with the device key, then run a command or open a terminal shell.
// Every failure ends promptly with a named error: a refused key, a changed host key, no answer in time.
// (SwiftNIO SSH alone waits forever when no login method is left; `Once` below turns that into .authRefused.)
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public enum SSHError: Error, Equatable {
    case authRefused
    case hostKeyChanged(pinned: String, offered: String)
    case timedOut
    case closed
    case keyStore(Int)
    case noRoute([String])

    /// The Mac answered and said no: trying another route to the same Mac would get the same answer.
    var endsRouteSearch: Bool {
        switch self { case .authRefused, .hostKeyChanged: return true; default: return false }
    }
}

/// Completes a promise only once; every callback runs on the connection's one event loop.
final class Once<T> {
    let promise: EventLoopPromise<T>
    private var done = false
    init(_ promise: EventLoopPromise<T>) { self.promise = promise }
    func succeed(_ v: T) { guard !done else { return }; done = true; promise.succeed(v) }
    func fail(_ e: Error) { guard !done else { return }; done = true; promise.fail(e) }
}

final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate {
    let server: String, pins: PinStore, ready: Once<Void>
    init(server: String, pins: PinStore, ready: Once<Void>) { self.server = server; self.pins = pins; self.ready = ready }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let offered = String(openSSHPublicKey: hostKey)
        if let pinned = pins.pin(for: server), pinned != offered {
            let e = SSHError.hostKeyChanged(pinned: pinned, offered: offered)
            ready.fail(e); validationCompletePromise.fail(e); return
        }
        if pins.pin(for: server) == nil { pins.setPin(offered, for: server) }
        validationCompletePromise.succeed(())
    }
}

final class KeyLogin: NIOSSHClientUserAuthenticationDelegate {
    let user: String, key: NIOSSHPrivateKey, ready: Once<Void>
    private var tried = false
    init(user: String, key: NIOSSHPrivateKey, ready: Once<Void>) { self.user = user; self.key = key; self.ready = ready }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !tried, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            ready.fail(SSHError.authRefused)  // nothing left to offer: fail now instead of waiting forever
            return
        }
        tried = true
        nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// Watches the parent channel for the login result and for errors.
final class LoginWatch: ChannelInboundHandler {
    typealias InboundIn = Any
    let ready: Once<Void>
    init(_ ready: Once<Void>) { self.ready = ready }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { ready.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { ready.fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { ready.fail(SSHError.closed); context.fireChannelInactive() }
}

public final class SSHConnection {
    let group: EventLoopGroup
    let channel: Channel
    public let server: String

    init(group: EventLoopGroup, channel: Channel, server: String) { self.group = group; self.channel = channel; self.server = server }

    /// Connects and logs in, or throws within `timeout`.
    public static func connect(host: String, port: Int = 22, user: String, key: DeviceKey, pins: PinStore,
                               timeout: TimeAmount = .seconds(8)) async throws -> SSHConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let ready = Once(loop.makePromise(of: Void.self))
        let server = "\(host):\(port)"
        let hostKeys = PinnedHostKey(server: server, pins: pins, ready: ready)
        let login = KeyLogin(user: user, key: key.nio, ready: ready)
        let timer = loop.scheduleTask(in: timeout) { ready.fail(SSHError.timedOut) }
        do {
            let channel = try await ClientBootstrap(group: loop).channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .client(.init(userAuthDelegate: login, serverAuthDelegate: hostKeys)),
                                      allocator: ch.allocator, inboundChildChannelInitializer: nil),
                        LoginWatch(ready),
                    ])
                }
            }.connectTimeout(timeout).connect(host: host, port: port).get()
            do { try await ready.promise.futureResult.get() } catch {
                try? await channel.close().get()
                throw error
            }
            timer.cancel()
            return SSHConnection(group: group, channel: channel, server: server)
        } catch {
            timer.cancel()
            loop.execute { ready.fail(error) }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Tries each address in order (LAN, then Tailscale, then tunnel); the first that logs in wins.
    /// A refused key or a changed host key stops the search: another route reaches the same Mac and would fail the same way.
    public static func connect(routes: [(host: String, port: Int)], user: String, key: DeviceKey, pins: PinStore,
                               timeout: TimeAmount = .seconds(5)) async throws -> SSHConnection {
        var tried: [String] = []
        for r in routes {
            do { return try await connect(host: r.host, port: r.port, user: user, key: key, pins: pins, timeout: timeout) }
            catch let e as SSHError where e.endsRouteSearch { throw e }
            catch { tried.append("\(r.host):\(r.port) (\(error))") }
        }
        throw SSHError.noRoute(tried)
    }

    func openChannel(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
        let p = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            self.channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { r in
                switch r {
                case .failure(let e): p.fail(e)
                case .success(let h):
                    h.createChannel(p) { child, type in
                        guard case .session = type else { return child.eventLoop.makeFailedFuture(SSHError.closed) }
                        return handler(child)
                    }
                }
            }
        }
        return try await p.futureResult.get()
    }

    /// Runs one command; returns everything it printed and its exit status.
    public func exec(_ command: String) async throws -> (output: String, status: Int) {
        let done = channel.eventLoop.makePromise(of: (String, Int).self)
        _ = try await openChannel { $0.pipeline.addHandler(ExecHandler(command, Once(done))) }
        let (out, status) = try await done.futureResult.get()
        return (out, status)
    }

    /// Opens an interactive shell with a terminal of `cols` × `rows`. Bytes from the Mac arrive in `onData`.
    public func shell(cols: Int, rows: Int, term: String = "xterm-256color",
                      onData: @escaping ([UInt8]) -> Void, onClose: @escaping () -> Void) async throws -> SSHShell {
        let started = channel.eventLoop.makePromise(of: Void.self)
        let child = try await openChannel {
            $0.pipeline.addHandler(ShellHandler(cols: cols, rows: rows, term: term, started: Once(started), onData: onData, onClose: onClose))
        }
        try await started.futureResult.get()
        return SSHShell(child)
    }

    public func close() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}

public final class SSHShell {
    let child: Channel
    init(_ child: Channel) { self.child = child }

    public func send(_ bytes: [UInt8]) {
        var b = child.allocator.buffer(capacity: bytes.count)
        b.writeBytes(bytes)
        child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(b)), promise: nil)
    }

    public func resize(cols: Int, rows: Int) {
        child.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0), promise: nil)
    }

    public func close() { child.close(promise: nil) }
}

final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let command: String, done: Once<(String, Int)>
    var out = "", status = -1
    init(_ command: String, _ done: Once<(String, Int)>) { self.command = command; self.done = done }
    func handlerAdded(context: ChannelHandlerContext) { _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) }
    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .byteBuffer(var b) = unwrapInboundIn(data).data { out += b.readString(length: b.readableBytes) ?? "" }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? SSHChannelRequestEvent.ExitStatus { status = e.exitStatus }
        if case ChannelEvent.inputClosed = event { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { done.succeed((out, status)) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { done.fail(error); context.close(promise: nil) }
}

final class ShellHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let cols: Int, rows: Int, term: String, started: Once<Void>
    let onData: ([UInt8]) -> Void, onClose: () -> Void
    init(cols: Int, rows: Int, term: String, started: Once<Void>, onData: @escaping ([UInt8]) -> Void, onClose: @escaping () -> Void) {
        self.cols = cols; self.rows = rows; self.term = term; self.started = started; self.onData = onData; self.onClose = onClose
    }
    func handlerAdded(context: ChannelHandlerContext) { _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) }
    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: term, terminalCharacterWidth: cols,
            terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        let ctx = context
        context.triggerUserOutboundEvent(pty).flatMap {
            ctx.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
        }.whenComplete { r in
            switch r { case .success: self.started.succeed(()); case .failure(let e): self.started.fail(e) }
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .byteBuffer(let b) = unwrapInboundIn(data).data { onData(Array(b.readableBytesView)) }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { started.fail(SSHError.closed); onClose() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { started.fail(error); context.close(promise: nil) }
}
