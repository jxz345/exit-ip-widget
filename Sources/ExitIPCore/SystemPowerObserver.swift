import Foundation
import IOKit.pwr_mgt

/// System-context wake observation; does not require WindowServer or a logged-in user.
@MainActor
final class SystemPowerObserver {
    private var port: IONotificationPortRef?
    private var connection: io_connect_t = 0
    private var notifier: io_object_t = 0
    private let wake: @MainActor () -> Void

    init(wake: @escaping @MainActor () -> Void) { self.wake = wake }

    func start() {
        guard connection == 0 else { return }
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, service, type, argument in
            guard let context else { return }
            let observer = Unmanaged<SystemPowerObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                // IOKit IOMessage.h: iokit_common_msg(0x270/0x280/0x300).
                switch type {
                case 0xe0000270, 0xe0000280:
                    IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
                case 0xe0000300: observer.wake()
                default: break
                }
            }
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, .main) }
    }

    func stop() {
        if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }
}
