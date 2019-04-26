//
//  ViewController.swift
//  OpalOCR
//
//  Created by David Liaw on 11/3/19.
//  Copyright © 2019 Liaw. All rights reserved.
//

import UIKit
import AVFoundation
import Vision
import SwiftOCR

class ViewController: UIViewController {

    private let captureSession = AVCaptureSession()
    private lazy var cameraLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    private let swiftOCRInstance = SwiftOCR()

    private var sampleBuffer: CMSampleBuffer?

    private let container = UIView()
    private let cardNumberLabel = UILabel()
    private let cardSecurityCode = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        setupAVSession()
        view.addSubview(container)
        container.addSubview(cardNumberLabel)
        container.addSubview(cardSecurityCode)

        container.backgroundColor = .white
        cardNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        cardSecurityCode.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cardNumberLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12.0),
            cardNumberLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12.0),
            cardSecurityCode.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 12.0),
            cardSecurityCode.topAnchor.constraint(equalTo: cardNumberLabel.bottomAnchor, constant: 12.0),
            cardSecurityCode.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12.0)
            ])

        captureSession.startRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        cameraLayer.frame = view.bounds
    }

    private func setupAVSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        defer {
            captureSession.commitConfiguration()
        }

        let output = AVCaptureVideoDataOutput()
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: backCamera),
            captureSession.canAddInput(input), captureSession.canAddOutput(output) else { return }

        captureSession.addInput(input)
        captureSession.addOutput(output)

        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "queue"))
        output.alwaysDiscardsLateVideoFrames = true

        let connection = output.connection(with: .video)
        connection?.videoOrientation = .portrait

        cameraLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(cameraLayer)

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: { [weak self] _ in
            if let sampleBuffer = self?.sampleBuffer {
                self?.handle(buffer: sampleBuffer)
            }
        })
    }
}

// AV
extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        self.sampleBuffer = sampleBuffer
    }
}

// Vision
extension ViewController {
    private func handle(buffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage: CGImage = CIContext.init(options: nil).createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)

        makeRequest(image: image)
    }

    private func makeRequest(image: UIImage) {
        guard let cgImage = image.cgImage else {
            assertionFailure()
            return
        }

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation.up,
            options: [VNImageOption: Any]()
        )

        let request = VNDetectTextRectanglesRequest(completionHandler: { [weak self] request, error in
            DispatchQueue.main.async {
                self?.handle(image: image, request: request, error: error)
            }
        })

        request.reportCharacterBoxes = true

        do {
            try handler.perform([request])
        } catch {
            print(error as Any)
        }
    }

    private func handle(image: UIImage, request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNTextObservation] else { return }
        handle(image: image, results: results)
    }
}

// Detection and OCR
extension ViewController {
    func handle(image: UIImage, results: [VNTextObservation]) {
        let results = results.filter { $0.confidence > 0.8 }

        // box
        let regex = try! NSRegularExpression(pattern: "(\\d{20})")
        results.forEach { result in
            let normalisedRect = normalise(box: result)
            if let croppedImage = cropImage(image: image, normalisedRect: normalisedRect) {
                swiftOCRInstance.recognize(croppedImage, { string in
                    // Trim alphabetical characters, replace all O with 0 (zero), and match regex
                    var replaced = string.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
                    replaced = replaced.replacingOccurrences(of: "O", with: "0")
                    let range = NSRange(location: 0, length: replaced.utf16.count)
                    let match = regex.firstMatch(in: replaced, options: [], range: range) != nil

                    // Only allow numerical matches that don't start with 1
                    // 1 is due to a mismatch where the L at the end of Opal is read as 1
                    if (match && CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: replaced)) && replaced.first != "1") {
                        DispatchQueue.main.sync {
                            self.cardNumberLabel.text = String(replaced.prefix(16))
                            self.cardSecurityCode.text = String(replaced.suffix(4))
                        }
                    }
                })
            }
        }
    }

    private func cropImage(image: UIImage, normalisedRect: CGRect) -> UIImage? {
        let x = normalisedRect.origin.x * image.size.width
        let y = normalisedRect.origin.y * image.size.height
        let width = normalisedRect.width * image.size.width
        let height = normalisedRect.height * image.size.height

        let rect = CGRect(x: x, y: y, width: width, height: height).scaleUp(scaleUp: 0.1)

        guard let cropped = image.cgImage?.cropping(to: rect) else {
            return nil
        }

        let croppedImage = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        return croppedImage
    }

    private func drawBox(overlayLayer: CALayer, normalisedRect: CGRect) {
        let x = normalisedRect.origin.x * overlayLayer.frame.size.width
        let y = normalisedRect.origin.y * overlayLayer.frame.size.height
        let width = normalisedRect.width * overlayLayer.frame.size.width
        let height = normalisedRect.height * overlayLayer.frame.size.height

        let outline = CALayer()
        outline.frame = CGRect(x: x, y: y, width: width, height: height).scaleUp(scaleUp: 0.1)
        outline.borderWidth = 2.0
        outline.borderColor = UIColor.red.cgColor

        overlayLayer.addSublayer(outline)
    }

    private func normalise(box: VNTextObservation) -> CGRect {
        return CGRect(
            x: box.boundingBox.origin.x,
            y: 1 - box.boundingBox.origin.y - box.boundingBox.height,
            width: box.boundingBox.size.width,
            height: box.boundingBox.size.height
        )
    }
}

extension CGRect {
    func scaleUp(scaleUp: CGFloat) -> CGRect {
        let biggerRect = self.insetBy(
            dx: -self.size.width * scaleUp,
            dy: -self.size.height * scaleUp
        )

        return biggerRect
    }
}
