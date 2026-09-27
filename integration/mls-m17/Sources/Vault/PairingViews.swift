import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders a pairing code (versioned, deterministic JSON bytes) as a QR image.
struct PairingCodeImage: View {
    let code: Data

    var body: some View {
        if let image = Self.render(code) {
            Image(decorative: image, scale: 1)
                .interpolation(.none).resizable().scaledToFit()
                .accessibilityLabel("Link code")
        } else {
            Image(systemName: "exclamationmark.triangle").accessibilityLabel("Link code unavailable")
        }
    }

    static func render(_ code: Data) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = code
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

enum CameraPermission: Equatable { case authorized, notDetermined, denied }

/// Camera authorization, injectable for tests.
protocol CameraAccess {
    var permission: CameraPermission { get }
    func requestAccess() async -> Bool
}

struct SystemCameraAccess: CameraAccess {
    var permission: CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
}

/// Full-screen scanner with an explicit Cancel. It stays up until a Watchlink
/// code is processed, the user cancels, or the camera fails.
struct PairingScannerScreen: View {
    let onCode: (Data) -> Bool
    let onCancel: () -> Void
    let onFailure: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            PairingScanner(onCode: onCode, onFailure: onFailure).ignoresSafeArea()
            HStack {
                Button("Cancel", action: onCancel).font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.35))
            Text("Scan your partner's Watchlink code").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white).padding(12).background(.black.opacity(0.35), in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 48)
        }
    }
}

/// Minimal native QR scanner. Nothing is logged or kept.
struct PairingScanner: UIViewControllerRepresentable {
    /// Returns true when the payload was consumed; false keeps scanning.
    let onCode: (Data) -> Bool
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((Data) -> Bool)?
        var onFailure: (() -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false
        private var ignored: Set<String> = []

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                fail()
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                fail()
                return
            }
            NotificationCenter.default.addObserver(self, selector: #selector(runtimeError),
                                                   name: AVCaptureSession.runtimeErrorNotification, object: session)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  !ignored.contains(value) else { return }
            if onCode?(Data(value.utf8)) == true {
                delivered = true
                session.stopRunning()
            } else {
                ignored.insert(value)  // not a Watchlink code: keep scanning, don't re-evaluate it
            }
        }

        @objc private func runtimeError() { DispatchQueue.main.async { self.fail() } }

        /// Reported asynchronously so a failure during presentation never races the presentation itself.
        private func fail() {
            guard !delivered else { return }
            delivered = true
            DispatchQueue.main.async { self.onFailure?() }
        }
    }
}
