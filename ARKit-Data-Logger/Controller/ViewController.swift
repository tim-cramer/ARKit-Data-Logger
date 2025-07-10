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
class NetworkManager: NSObject, URLSessionTaskDelegate {

    private var progressHandler: ((Float) -> Void)?

    func uploadFile(fileURL: URL, to serverEndpoint: String, progressHandler: @escaping (Float) -> Void, completion: @escaping (Result<Void, UploadError>) -> Void) {
        
        self.progressHandler = progressHandler
        
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
        configuration.timeoutIntervalForRequest = 10.0 // 10 second timeout
        
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
        DispatchQueue.main.async {
            self.progressHandler?(progress)
        }
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
    @IBOutlet weak var progressView: UIProgressView!
    
    // MARK: - Properties
    var isRecording: Bool = false
    let customQueue = DispatchQueue(label: "com.yourapp.arkitlogger", qos: .userInitiated, attributes: .concurrent)
    let captureInterval: TimeInterval = 1.0 / 5.0 // 5 FPS
    var lastCaptureTime: TimeInterval = 0
    
    let poseDataBatchSize = 100
    var poseDataBuffer: [String] = []
    
    let ARKIT_LIDAR_POSE_FILE = 0
    var fileHandlers: [FileHandle] = []
    var sessionPath: URL?
    
    let TARGET_MAX_LENGTH: CGFloat = 640.0
    
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
        statusLabel.adjustsFontSizeToFitWidth = true
        progressView.progress = 0
        progressView.isHidden = true
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
            self.startStopButton.isEnabled = false
            self.progressView.isHidden = false
            self.progressView.progress = 0
        }

        customQueue.async {
            self.flushPoseBuffer()
            self.closeFiles()
            
            DispatchQueue.main.async { self.statusLabel.text = "Zipping files..." }
            
            guard let zipURL = self.zipSessionFolder(at: self.sessionPath, progressHandler: { zipProgress in
                let overallProgress = Float(zipProgress) * 0.2
                self.progressView.setProgress(overallProgress, animated: true)
            }) else {
                self.errorMsg(msg: "Failed to create zip file.")
                DispatchQueue.main.async { self.resetUIState() }
                return
            }
            
            DispatchQueue.main.async { self.statusLabel.text = "Uploading to server..." }
            
            self.networkManager.uploadFile(fileURL: zipURL, to: self.serverEndpoint, progressHandler: { uploadProgress in
                let overallProgress = 0.2 + (uploadProgress * 0.8)
                self.progressView.setProgress(overallProgress, animated: true)
            }) { [weak self] result in
                guard let self = self else { return }
                
                try? FileManager.default.removeItem(at: zipURL)
                
                switch result {
                case .success:
                    self.statusLabel.text = "✅ Upload Complete!"
                    if let sessionPath = self.sessionPath {
                        try? FileManager.default.removeItem(at: sessionPath)
                    }
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
        
        customQueue.async {
            let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)

            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                os_log("FATAL: Failed to create CGImage from CIImage.", log: .default, type: .fault)
                return
            }
            
            // ✅ SIMPLIFIED: Create a UIImage with no rotation. It remains in its native landscape orientation.
            let landscapeImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
            
            guard let resizedImage = landscapeImage.resizedToFit(maxLength: self.TARGET_MAX_LENGTH) else {
                os_log("FATAL: Image resizing failed.", log: .default, type: .fault)
                return
            }
            
            guard let pngData = resizedImage.pngData() else {
                os_log("FATAL: Could not get PNG data from the resized image.", log: .default, type: .fault)
                return
            }

            self.logPose(timestamp: timestamp, transform: frame.camera.transform)
            self.logImage(timestamp: timestamp, pngData: pngData)
            self.logIntrinsics(for: frame, timestamp: timestamp)
        }
        
        DispatchQueue.main.async {
            self.updateDebugUI(with: frame)
        }
    }
    
    // MARK: - Logging Logic
    private func logPose(timestamp: TimeInterval, transform: simd_float4x4) {
        let cameraToWorld = transform
        let translation = cameraToWorld.columns.3

        let rotationMatrix = simd_float3x3(
            SIMD3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
            SIMD3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
            SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        )

        // Convert to quaternion
        let rotationQuat = simd_quatf(rotationMatrix)
        let axis = rotationQuat.axis
        let angle = rotationQuat.angle
        let rotationVector = SIMD3<Float>(axis.x * angle, axis.y * angle, axis.z * angle)

        let poseString = String(format: "%.8f %.8f %.8f %.8f %.8f %.8f %.8f\n",
            timestamp, // possibly in seconds!
            rotationVector.x, rotationVector.y, rotationVector.z,
            translation.x, translation.y, translation.z
            
        )
        poseDataBuffer.append(poseString)
    }
    
    private func logImage(timestamp: TimeInterval, pngData: Data) {
        guard let lowresWidePath = self.sessionPath?.appendingPathComponent("lowres_wide") else { return }
        let nanosecondTimestamp = timestamp * 1_000_000_000
        let filename = lowresWidePath.appendingPathComponent("\(String(format: "%.0f", nanosecondTimestamp)).png")
        
        do {
            try pngData.write(to: filename)
        } catch {
            os_log("Failed to write PNG data: %@", log: .default, type: .error, error.localizedDescription)
        }
    }
    
    // MARK: - ✅ SIMPLIFIED Intrinsics Logging for Landscape
    private func logIntrinsics(for frame: ARFrame, timestamp: TimeInterval) {
        guard let intrinsicsPath = self.sessionPath?.appendingPathComponent("lowres_wide_intrinsics") else { return }

        // Get native landscape intrinsics
        let intrinsics = frame.camera.intrinsics
        
        // Get original dimensions
        let originalWidth = CGFloat(CVPixelBufferGetWidth(frame.capturedImage))
        let originalHeight = CGFloat(CVPixelBufferGetHeight(frame.capturedImage))
        
        // ✅ FIXED: Calculate proper scaling for resized image
        let aspectRatio = originalWidth / originalHeight
        var newWidth: CGFloat
        var newHeight: CGFloat
        
        if originalWidth > originalHeight {
            newWidth = TARGET_MAX_LENGTH
            newHeight = TARGET_MAX_LENGTH / aspectRatio
        } else {
            newWidth = TARGET_MAX_LENGTH * aspectRatio
            newHeight = TARGET_MAX_LENGTH
        }
        
        let scaleX = Float(newWidth) / Float(originalWidth)
        let scaleY = Float(newHeight) / Float(originalHeight)
        
        // Scale intrinsics appropriately
        let scaledFx = intrinsics.columns.0.x * scaleX
        let scaledFy = intrinsics.columns.1.y * scaleY
        let scaledCx = intrinsics.columns.2.x * scaleX
        let scaledCy = intrinsics.columns.2.y * scaleY
        
        // ✅ IMPORTANT: Also log the actual image dimensions for unprojection
        let intrinsicsLine = "\(Int(newWidth)) \(Int(newHeight)) \(scaledFx) \(scaledFy) \(scaledCx) \(scaledCy)\n"
        
        let nanosecondTimestamp = timestamp * 1_000_000_000
        let filename = intrinsicsPath.appendingPathComponent("\(String(format: "%.0f", nanosecondTimestamp)).pincam")

        do {
            if let dataToWrite = intrinsicsLine.data(using: .utf8) {
                try dataToWrite.write(to: filename)
            }
        } catch {
            os_log("Failed to write pincam file: %@", log: .default, type: .error, error.localizedDescription)
        }
    }
    // MARK: - File I/O & Zipping
    private func createSessionDirectoryAndFiles() -> Bool {
        fileHandlers.removeAll(); poseDataBuffer.removeAll()
            
        guard let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
            
        let newSessionPath = docPath.appendingPathComponent("arkit_session_\(timeToString(true))")
        let lowresWidePath = newSessionPath.appendingPathComponent("lowres_wide")
        let lowresIntrinsicsPath = newSessionPath.appendingPathComponent("lowres_wide_intrinsics")

        do {
            try FileManager.default.createDirectory(at: lowresWidePath, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: lowresIntrinsicsPath, withIntermediateDirectories: true, attributes: nil)
            self.sessionPath = newSessionPath
        } catch {
            os_log("Failed to create session directories: %@", log: .default, type: .error, error.localizedDescription)
            return false
        }
            
        let fileName = "lowres_wide.traj"
        let url = newSessionPath.appendingPathComponent(fileName)
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            let fileHandle = try FileHandle(forWritingTo: url)
            fileHandlers.append(fileHandle)
        } catch {
            os_log("Failed to create file handle for %@: %@", log: .default, type: .error, url.lastPathComponent, error.localizedDescription)
            return false
        }
            
        return true
    }

    private func flushPoseBuffer() {
        guard !poseDataBuffer.isEmpty, fileHandlers.indices.contains(ARKIT_LIDAR_POSE_FILE) else { return }
        
        let bufferString = poseDataBuffer.joined()
        if let data = bufferString.data(using: .utf8) {
            fileHandlers[ARKIT_LIDAR_POSE_FILE].write(data)
        }
        poseDataBuffer.removeAll()
    }
    
    private func closeFiles() {
        fileHandlers.forEach { $0.closeFile() }
    }
    
    private func zipSessionFolder(at sourceURL: URL?, progressHandler: @escaping (Double) -> Void) -> URL? {
        guard let sourceURL = sourceURL else { return nil }
        
        do {
            let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(sourceURL.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: zipURL)
            
            try Zip.zipFiles(paths: [sourceURL], zipFilePath: zipURL, password: nil, progress: { progress in
                DispatchQueue.main.async {
                    progressHandler(progress)
                }
            })
            
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
        progressView.isHidden = true
        progressView.progress = 0
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

extension UIImage {
    func resizedToFit(maxLength: CGFloat) -> UIImage? {
        guard let cgImage = self.cgImage else {
            os_log("Resize failed: Could not get CGImage.", log: .default, type: .error)
            return nil
        }
        
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)

        let aspectRatio = originalWidth / originalHeight
        var newSize: CGSize
        
        if originalWidth > originalHeight {
            newSize = CGSize(width: maxLength, height: maxLength / aspectRatio)
        } else {
            newSize = CGSize(width: maxLength * aspectRatio, height: maxLength)
        }
        
        let width = Int(newSize.width)
        let height = Int(newSize.height)
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            os_log("Failed to create CGContext for resizing", log: .default, type: .error)
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let resizedCGImage = context.makeImage() else {
            os_log("Failed to create resized CGImage", log: .default, type: .error)
            return nil
        }
        
        // ✅ FIXED: Maintain consistent orientation
        let resizedImage = UIImage(cgImage: resizedCGImage, scale: 1.0, orientation: .up)
        
        return resizedImage
    }
}

private func validateCameraSetup(for frame: ARFrame) {
    // This is helpful for debugging your 3D unprojection pipeline
    let transform = frame.camera.transform
    let intrinsics = frame.camera.intrinsics
    
    // Log camera parameters for validation
    os_log("Camera Transform (Camera-to-World):", log: .default, type: .info)
    os_log("  Translation: [%.3f, %.3f, %.3f]", log: .default, type: .info,
           transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    
    os_log("Intrinsics Matrix:", log: .default, type: .info)
    os_log("  fx=%.2f, fy=%.2f, cx=%.2f, cy=%.2f", log: .default, type: .info,
           intrinsics.columns.0.x, intrinsics.columns.1.y,
           intrinsics.columns.2.x, intrinsics.columns.2.y)
    
    let imageResolution = frame.camera.imageResolution
    os_log("Image Resolution: %.0f x %.0f", log: .default, type: .info,
           imageResolution.width, imageResolution.height)
}
