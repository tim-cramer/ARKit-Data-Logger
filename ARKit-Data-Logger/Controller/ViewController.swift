import UIKit
import SceneKit
import ARKit
import os.log
import Zip // 👈 Add this import for the zipping functionality

class ViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    
    // MARK: - IBOutlets
    @IBOutlet weak var startStopButton: UIButton!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet var sceneView: ARSCNView!
    @IBOutlet weak var numberOfFeatureLabel: UILabel!
    @IBOutlet weak var trackingStatusLabel: UILabel!
    @IBOutlet weak var worldMappingStatusLabel: UILabel!
    @IBOutlet weak var updateRateLabel: UILabel!
    
    // MARK: - Properties
    var isRecording: Bool = false
    let customQueue = DispatchQueue(label: "me.pyojinkim.arkitlogger", qos: .userInitiated, attributes: .concurrent)
    let captureInterval: TimeInterval = 1.0 / 10.0 // 10 FPS
    var lastCaptureTime: TimeInterval = 0
    
    let poseDataBatchSize = 100
    var poseDataBuffer: [String] = []
    
    let ARKIT_CAMERA_POSE = 0
    let ARKIT_CAMERA_INTRINSICS = 1
    var fileHandlers: [FileHandle] = []
    var sessionPath: URL?
    
    var recordingTimer: Timer?
    var secondCounter: Int64 = 0 {
        didSet { statusLabel.text = interfaceIntTime(second: secondCounter) }
    }
    
    // The CIContext is used for converting pixel buffers to image data.
    let ciContext = CIContext(options: nil)

    // MARK: - View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupAR()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        restartARSession()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }
    
    // MARK: - Setup
    private func setupUI() {
        statusLabel.text = "Ready"
    }

    private func setupAR() {
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.debugOptions = [ARSCNDebugOptions.showFeaturePoints, ARSCNDebugOptions.showWorldOrigin]
    }

    func restartARSession() {
        let configuration = ARWorldTrackingConfiguration()
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Main Action
    @IBAction func startStopButtonPressed(_ sender: UIButton) {
        if !isRecording {
            customQueue.async {
                guard self.createSessionDirectoryAndFiles() else {
                    self.errorMsg(msg: "Failed to create files.")
                    return
                }
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.updateUIForRecording(true)
                }
            }
        } else {
            isRecording = false
            updateUIForRecording(false)

            customQueue.async {
                self.flushPoseBuffer()
                self.closeFiles()
                
                if let zipURL = self.zipSessionFolder(at: self.sessionPath) {
                    DispatchQueue.main.async {
                        self.presentShareSheet(for: zipURL)
                    }
                } else {
                    self.errorMsg(msg: "Failed to create zip file.")
                }
            }
        }
    }

    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording, frame.timestamp - lastCaptureTime >= captureInterval else { return }
        lastCaptureTime = frame.timestamp
        
        // --- PERFORMANCE FIX ---
        // Capture the necessary properties from the frame on the main thread.
        let timestamp = frame.timestamp
        let cameraTransform = frame.camera.transform
        let capturedImage = frame.capturedImage // This is a CVPixelBuffer
        
        // Dispatch all heavy work to the background queue.
        customQueue.async {
            // 1. Do the slow image conversion IN THE BACKGROUND.
            let jpgData = self.uiImageFrom(pixelBuffer: capturedImage)?.jpegData(compressionQuality: 0.75)
            
            // 2. Log the pose data.
            self.logPose(timestamp: timestamp, transform: cameraTransform)
            
            // 3. Write the image data to a file.
            if let data = jpgData {
                self.logImage(timestamp: timestamp, jpgData: data)
            }
        }
        
        // Update the UI on the main thread.
        DispatchQueue.main.async {
            self.updateDebugUI(with: frame)
        }
    }
    
    // MARK: - Logging Logic
    private func logPose(timestamp: TimeInterval, transform: simd_float4x4) {
        let nanosecondTimestamp = timestamp * 1_000_000_000
        let poseString = String(format: "%.0f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f\n",
                                nanosecondTimestamp,
                                transform.columns.0.x, transform.columns.1.x, transform.columns.2.x, transform.columns.3.x,
                                transform.columns.0.y, transform.columns.1.y, transform.columns.2.y, transform.columns.3.y,
                                transform.columns.0.z, transform.columns.1.z, transform.columns.2.z, transform.columns.3.z)
        
        poseDataBuffer.append(poseString)
        if poseDataBuffer.count >= poseDataBatchSize {
            flushPoseBuffer()
        }
    }
    
    private func logImage(timestamp: TimeInterval, jpgData: Data) {
        guard let colorPath = self.sessionPath?.appendingPathComponent("color") else { return }
        let nanosecondTimestamp = timestamp * 1_000_000_000
        let filename = colorPath.appendingPathComponent("\(String(format: "%.0f", nanosecondTimestamp)).jpg")
        
        do {
            try jpgData.write(to: filename)
        } catch {
            os_log("Failed to write JPG data: %@", log: .default, type: .error, error.localizedDescription)
        }
    }
    
    private func uiImageFrom(pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        }
        return nil
    }
    
    // MARK: - File I/O & Sharing
    private func createSessionDirectoryAndFiles() -> Bool {
        fileHandlers.removeAll(); poseDataBuffer.removeAll()
        
        guard let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        
        let newSessionPath = docPath.appendingPathComponent("arkit_session_\(timeToString(true))")
        let colorFolderPath = newSessionPath.appendingPathComponent("color")

        do {
            try FileManager.default.createDirectory(at: colorFolderPath, withIntermediateDirectories: true, attributes: nil)
            self.sessionPath = newSessionPath
        } catch {
            os_log("Failed to create session directory: %@", log: .default, type: .error, error.localizedDescription)
            return false
        }
        
        let fileNames = ["ARKit_camera_pose.txt", "ARKit_camera_intrinsics.txt"]
        for i in 0..<fileNames.count {
            let url = newSessionPath.appendingPathComponent(fileNames[i])
            do {
                try "".write(to: url, atomically: true, encoding: .utf8)
                let fileHandle = try FileHandle(forWritingTo: url)
                fileHandlers.append(fileHandle)
            } catch {
                os_log("Failed to create file handle for %@: %@", log: .default, type: .error, url.lastPathComponent, error.localizedDescription)
                return false
            }
        }
        
        let timeHeader = "# Created at \(timeToString())\n"
        fileHandlers.forEach { $0.write(timeHeader.data(using: .utf8)!) }
        
        fileHandlers[ARKIT_CAMERA_INTRINSICS].write("fx, fy, ox, oy\n".data(using: .utf8)!)
        if let intrinsics = sceneView.session.currentFrame?.camera.intrinsics {
            let i = intrinsics.columns
            fileHandlers[ARKIT_CAMERA_INTRINSICS].write("\(i.0.x), \(i.1.y), \(i.2.x), \(i.2.y)\n".data(using: .utf8)!)
        }
        
        return true
    }
    
    private func flushPoseBuffer() {
        guard !poseDataBuffer.isEmpty, fileHandlers.indices.contains(ARKIT_CAMERA_POSE) else { return }
        fileHandlers[ARKIT_CAMERA_POSE].write(poseDataBuffer.joined().data(using: .utf8)!)
        poseDataBuffer.removeAll()
    }
    
    private func closeFiles() {
        fileHandlers.forEach { $0.closeFile() }
    }
    
    private func presentShareSheet(for url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = self.startStopButton.frame
        }
        activityVC.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        self.present(activityVC, animated: true)
    }

    // --- ZIPPING FIX ---
    // This function now uses the Zip library to create a valid zip archive.
    private func zipSessionFolder(at sourceURL: URL?) -> URL? {
        guard let sourceURL = sourceURL else { return nil }
        
        do {
            let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(sourceURL.lastPathComponent + ".zip")
            
            // This will create a REAL zip file at the destination URL
            try Zip.zipFiles(paths: [sourceURL], zipFilePath: zipURL, password: nil, progress: nil)
            
            return zipURL
        } catch {
            os_log("Failed to create zip file: %@", log: .default, type: .error, error.localizedDescription)
            return nil
        }
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
            startStopButton.setTitle("Start", for: .normal)
            startStopButton.setTitleColor(.systemGreen, for: .normal)
            UIApplication.shared.isIdleTimerDisabled = false
            recordingTimer?.invalidate()
            statusLabel.text = "Ready"
            [numberOfFeatureLabel, trackingStatusLabel, worldMappingStatusLabel, updateRateLabel].forEach { $0?.text = "-" }
        }
    }
    
    private func updateDebugUI(with frame: ARFrame) {
        numberOfFeatureLabel.text = String(format: "%d", frame.rawFeaturePoints?.points.count ?? 0)
        trackingStatusLabel.text = string(for: frame.camera.trackingState)
        
        var statusText = ""
        switch frame.worldMappingStatus {
        case .notAvailable: statusText = "Not Available"
        case .limited: statusText = "Limited"
        case .extending: statusText = "Extending"
        case .mapped: statusText = "Mapped"
        @unknown default: statusText = "Unknown"
        }
        worldMappingStatusLabel.text = statusText
    }
    
    private func errorMsg(msg: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alert, animated: true)
        }
    }
    
    private func string(for trackingState: ARCamera.TrackingState) -> String {
        switch trackingState {
        case .notAvailable: return "Not Available"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "Limited: Excessive Motion"
            case .insufficientFeatures: return "Limited: Insufficient Features"
            case .initializing: return "Limited: Initializing"
            case .relocalizing: return "Limited: Relocalizing"
            @unknown default: return "Limited: Unknown Reason"
            }
        case .normal: return "Normal"
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
