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

/// Minimal native QR scanner. Delivers the raw payload once; nothing is logged or kept.
struct PairingScanner: UIViewControllerRepresentable {
    let onCode: (Data) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((Data) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
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
            guard !delivered, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
            else { return }
            delivered = true
            session.stopRunning()
            onCode?(Data(value.utf8))
        }
    }
}
