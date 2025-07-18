import UIKit
import AVFoundation
import os.log

class ViewController: UIViewController {

    // MARK: - IBOutlets
    @IBOutlet weak var startStopButton: UIButton!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var progressView: UIProgressView!

    // MARK: - Properties
    var isRecording: Bool = false
    let customQueue = DispatchQueue(label: "com.yourapp.cameracapture", qos: .userInitiated)

    var sessionPath: URL?
    var imageFilePaths: [URL] = []

    var recordingTimer: Timer?
    var secondCounter: Int64 = 0 {
        didSet {
            if isRecording {
                statusLabel.text = "Recording: \(interfaceIntTime(second: secondCounter))"
            }
        }
    }

    let networkManager = NetworkManager()
    let serverEndpoint = "http://10.1.74.4:8080/v1/scenes"

    // Camera Capture Properties
    private var captureSession: AVCaptureSession?
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var captureTimer: Timer?
    private let captureInterval: TimeInterval = 1.0 / 1.0 // 5 FPS

    // MARK: - View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Ensure the preview layer always fills the screen
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop the session when the view disappears
        if self.captureSession?.isRunning == true {
            self.captureSession?.stopRunning()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Start the session again when the view appears
        if self.captureSession?.isRunning == false {
            customQueue.async {
                self.captureSession?.startRunning()
            }
        }
    }

    // MARK: - Setup
    private func setupUI() {
        statusLabel.text = "Ready to Record"
        statusLabel.adjustsFontSizeToFitWidth = true
        progressView.progress = 0
        progressView.isHidden = true
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480 // hd .hd1920x1080, highest .photo, generic .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            errorMsg(msg: "Failed to setup camera device.")
            return
        }

        if session.canAddInput(input) && session.canAddOutput(photoOutput) {
            session.addInput(input)
            session.addOutput(photoOutput)

            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = self.view.bounds

            // Add the preview layer to the view hierarchy
            self.view.layer.insertSublayer(previewLayer, at: 0)

            customQueue.async {
                session.startRunning()
            }
            self.captureSession = session

        } else {
            errorMsg(msg: "Failed to initialize camera session.")
        }
    }

    // MARK: - Main Action
    @IBAction func startStopButtonPressed(_ sender: UIButton) {
        if !isRecording {
            customQueue.async {
                guard self.createSessionDirectory() else {
                    self.errorMsg(msg: "Failed to create session directory.")
                    return
                }
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.updateUIForRecording(true)
                    self.startCaptureTimer()
                }
            }
        } else {
            isRecording = false
            updateUIForRecording(false)
            stopCaptureTimer()
            processAndUploadData()
        }
    }

    private func processAndUploadData() {
        DispatchQueue.main.async {
            self.statusLabel.text = "Processing data..."
            self.startStopButton.isEnabled = false
            self.progressView.isHidden = false
            self.progressView.progress = 0
        }

        customQueue.async {
            DispatchQueue.main.async { self.statusLabel.text = "Uploading to server..." }

            self.networkManager.uploadImages(fileURLs: self.imageFilePaths, to: self.serverEndpoint, progressHandler: { uploadProgress in
                self.progressView.setProgress(uploadProgress, animated: true)
            }) { [weak self] result in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.statusLabel.text = "✅ Upload Complete!"
                        if let sessionPath = self.sessionPath {
                            try? FileManager.default.removeItem(at: sessionPath)
                        }
                    case .failure(let error):
                        self.errorMsg(msg: error.localizedDescription)
                        self.statusLabel.text = "❌ Upload Failed"
                    }
                    self.resetUIState()
                }
            }
        }
    }

    // MARK: - Image Capture
    private func startCaptureTimer() {
        imageFilePaths.removeAll()
        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.capturePhoto()
        }
    }

    private func stopCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = nil
    }

    private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - File I/O
    private func createSessionDirectory() -> Bool {
        guard let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }

        let newSessionPath = docPath.appendingPathComponent("capture_session_\(timeToString(true))")
        let imagesPath = newSessionPath.appendingPathComponent("images")

        do {
            try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true, attributes: nil)
            self.sessionPath = newSessionPath
        } catch {
            os_log("Failed to create session directories: %@", log: .default, type: .error, error.localizedDescription)
            return false
        }

        return true
    }

    // MARK: - UI Helpers
    private func updateUIForRecording(_ isRecording: Bool) {
        if isRecording {
            startStopButton.setTitle("Stop", for: .normal)
            startStopButton.setTitleColor(.systemRed, for: .normal)
            UIApplication.shared.isIdleTimerDisabled = true
            secondCounter = 0
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.secondCounter += 1
            }
        } else {
            recordingTimer?.invalidate()
            startStopButton.setTitle("Process & Upload", for: .normal)
            startStopButton.setTitleColor(.systemBlue, for: .normal)
            statusLabel.text = "Processing..."
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func resetUIState() {
        startStopButton.isEnabled = true
        startStopButton.setTitle("Start", for: .normal)
        startStopButton.setTitleColor(.systemGreen, for: .normal)
        statusLabel.text = "Ready to Record"
        progressView.isHidden = true
        progressView.progress = 0
    }

    private func errorMsg(msg: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alert, animated: true)
        }
    }

    func interfaceIntTime(second: Int64) -> String {
        let minutes = (second / 60) % 60, seconds = second % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func timeToString(_ forFilename: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = forFilename ? "yyyy-MM-dd_HH-mm-ss" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension ViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            os_log("Error capturing photo: %@", log: .default, type: .error, error.localizedDescription)
            return
        }

        guard let imageData = photo.fileDataRepresentation(), let imagesPath = self.sessionPath?.appendingPathComponent("images") else { return }

        let timestamp = Date().timeIntervalSince1970
        let nanosecondTimestamp = timestamp * 1_000_000_000
        let filename = imagesPath.appendingPathComponent("\(String(format: "%.0f", nanosecondTimestamp)).jpg")

        customQueue.async {
            do {
                try imageData.write(to: filename)
                self.imageFilePaths.append(filename)
            } catch {
                os_log("Failed to write image data: %@", log: .default, type: .error, error.localizedDescription)
            }
        }
    }
}
