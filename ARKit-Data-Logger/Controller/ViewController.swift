import UIKit
import SceneKit
import ARKit
import os.log
import Zip

enum UploadError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case httpError(statusCode: Int, serverMessage: String?)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL was invalid."
        case .networkError(let error):
            // Check if the error is a timeout.
            if let urlError = error as? URLError, urlError.code == .timedOut {
                return "The connection timed out. Please check the server IP address and your Wi-Fi connection."
            }
            return "Network error: \(error.localizedDescription)"
        case .httpError(let statusCode, let message):
            return "Upload failed with HTTP status \(statusCode). Server says: \(message ?? "No message")"
        case .noData:
            return "No data received from server."
        }
    }
}

/// A helper class to handle network requests for uploading data.
class NetworkManager {

    /// Uploads a file to a specified server URL using an HTTP POST request.
    func uploadFile(fileURL: URL, to serverEndpoint: String, completion: @escaping (Result<Void, UploadError>) -> Void) {
        
        guard let url = URL(string: serverEndpoint) else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var data = Data()

        do {
            let fileData = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            
            data.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: application/zip\r\n\r\n".data(using: .utf8)!)
            data.append(fileData)
            data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        } catch {
            completion(.failure(.networkError(error)))
            return
        }
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10.0
        
        let session = URLSession(configuration: configuration)
        
        let task = session.uploadTask(with: request, from: data) { responseData, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.noData))
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    var serverMessage: String?
                    if let responseData = responseData {
                        serverMessage = String(data: responseData, encoding: .utf8)
                    }
                    completion(.failure(.httpError(statusCode: httpResponse.statusCode, serverMessage: serverMessage)))
                    return
                }

                completion(.success(()))
            }
        }
        task.resume()
    }
}


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
        didSet {
            if isRecording {
                statusLabel.text = "Recording: \(interfaceIntTime(second: secondCounter))"
            }
        }
    }
    
    let ciContext = CIContext(options: nil)

    let networkManager = NetworkManager()
    // ‼️ IMPORTANT: Replace this with your computer's local IP address.
    let serverEndpoint = "http://10.1.74.4:8080/process-scene"
    
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
        statusLabel.text = "Ready to Record"
        statusLabel.adjustsFontSizeToFitWidth = true // Allow text to shrink if needed
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
                    self.errorMsg(msg: "Failed to create session directory.")
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

            processAndUploadData()
        }
    }
    
    private func processAndUploadData() {
        DispatchQueue.main.async {
            self.statusLabel.text = "Processing data..."
            self.startStopButton.isEnabled = false // Disable button to prevent multiple taps
        }

        customQueue.async {
            self.flushPoseBuffer()
            self.closeFiles()
            
            DispatchQueue.main.async { self.statusLabel.text = "Zipping files..." }
            guard let zipURL = self.zipSessionFolder(at: self.sessionPath) else {
                self.errorMsg(msg: "Failed to create zip file.")
                DispatchQueue.main.async { self.resetUIState() }
                return
            }
            
            DispatchQueue.main.async { self.statusLabel.text = "Uploading to server..." }
            
            self.networkManager.uploadFile(fileURL: zipURL, to: self.serverEndpoint) { [weak self] result in
                guard let self = self else { return }
                
                try? FileManager.default.removeItem(at: zipURL)
                
                switch result {
                case .success:
                    self.statusLabel.text = "✅ Upload Complete!"
                    self.startStopButton.isEnabled = true
                    self.resetUIState()
                    
                case .failure(let error):
                    self.errorMsg(msg: error.localizedDescription)
                    self.statusLabel.text = "❌ Upload Failed"
                    self.resetUIState()
                }
            }
        }
    }


    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording, frame.timestamp - lastCaptureTime >= captureInterval else { return }
        lastCaptureTime = frame.timestamp
        
        let timestamp = frame.timestamp
        let cameraTransform = frame.camera.transform
        let capturedImage = frame.capturedImage
        
        customQueue.async {
            let jpgData = self.uiImageFrom(pixelBuffer: capturedImage)?.jpegData(compressionQuality: 0.75)
            self.logPose(timestamp: timestamp, transform: cameraTransform)
            if let data = jpgData {
                self.logImage(timestamp: timestamp, jpgData: data)
            }
        }
        
        DispatchQueue.main.async {
            self.updateDebugUI(with: frame)
        }
    }
    
    // MARK: - Logging Logic (Unchanged)
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
    
    // MARK: - File I/O & Zipping (Unchanged)
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

    private func zipSessionFolder(at sourceURL: URL?) -> URL? {
        guard let sourceURL = sourceURL else { return nil }
        
        do {
            let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(sourceURL.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: zipURL)
            
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
            recordingTimer?.invalidate()
            startStopButton.setTitle("Process & Upload", for: .normal)
            startStopButton.setTitleColor(.systemBlue, for: .normal)
            statusLabel.text = "Processing..."
            UIApplication.shared.isIdleTimerDisabled = false
            [numberOfFeatureLabel, trackingStatusLabel, worldMappingStatusLabel, updateRateLabel].forEach { $0?.text = "-" }
        }
    }
    
    private func resetUIState() {
        startStopButton.isEnabled = true
        startStopButton.setTitle("Start", for: .normal)
        startStopButton.setTitleColor(.systemGreen, for: .normal)
        statusLabel.text = "Ready to Record"
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
