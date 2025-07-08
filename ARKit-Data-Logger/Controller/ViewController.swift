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
// MARK: - MODIFIED: Made NetworkManager an NSObject subclass to conform to URLSessionTaskDelegate
class NetworkManager: NSObject, URLSessionTaskDelegate {

    // MARK: - ADDED: Property to hold the progress handler
    private var progressHandler: ((Float) -> Void)?

    /// Uploads a file to a specified server URL using an HTTP POST request.
    // MARK: - MODIFIED: Added a progressHandler parameter
    func uploadFile(fileURL: URL, to serverEndpoint: String, progressHandler: @escaping (Float) -> Void, completion: @escaping (Result<Void, UploadError>) -> Void) {
        
        // MARK: - ADDED: Store the progress handler
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
        
        // MARK: - MODIFIED: Initialize session with delegate to self to receive progress updates
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

    // MARK: - ADDED: URLSessionTaskDelegate method to track upload progress
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
        // This delegate method is called on a background thread, so dispatch to main for the handler.
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
    
    // MARK: - ADDED: Connect this to a UIProgressView in your Storyboard
    @IBOutlet weak var progressView: UIProgressView!
    
    // MARK: - Properties
    var isRecording: Bool = false
    let customQueue = DispatchQueue(label: "me.pyojinkim.arkitlogger", qos: .userInitiated, attributes: .concurrent)
    let captureInterval: TimeInterval = 1.0 / 5.0 // 5 FPS
    var lastCaptureTime: TimeInterval = 0
    
    let poseDataBatchSize = 100
    var poseDataBuffer: [String] = []
    
    let ARKIT_CAMERA_POSE = 0
    let ARKIT_CAMERA_INTRINSICS = 1
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
        
        // MARK: - ADDED: Configure progress view
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
            self.startStopButton.isEnabled = false // Disable button to prevent multiple taps
            
            // MARK: - ADDED: Show and reset progress view
            self.progressView.isHidden = false
            self.progressView.progress = 0
        }

        customQueue.async {
            self.flushPoseBuffer()
            self.closeFiles()
            
            DispatchQueue.main.async { self.statusLabel.text = "Zipping files..." }
            
            // MARK: - MODIFIED: Call the new zip function with a progress handler
            guard let zipURL = self.zipSessionFolder(at: self.sessionPath, progressHandler: { zipProgress in
                // Zipping will account for the first 20% of the total progress.
                let overallProgress = Float(zipProgress) * 0.2
                self.progressView.setProgress(overallProgress, animated: true)
            }) else {
                self.errorMsg(msg: "Failed to create zip file.")
                DispatchQueue.main.async { self.resetUIState() }
                return
            }
            
            DispatchQueue.main.async { self.statusLabel.text = "Uploading to server..." }
            
            // MARK: - MODIFIED: Call the new upload function with a progress handler
            self.networkManager.uploadFile(fileURL: zipURL, to: self.serverEndpoint, progressHandler: { uploadProgress in
                // Uploading will account for the remaining 80% of the progress.
                let overallProgress = 0.2 + (uploadProgress * 0.8)
                self.progressView.setProgress(overallProgress, animated: true)
            }) { [weak self] result in
                guard let self = self else { return }
                
                // Delete the local zip file
                try? FileManager.default.removeItem(at: zipURL)
                
                switch result {
                case .success:
                    self.statusLabel.text = "✅ Upload Complete!"
                    
                    // MARK: - ADDED: Delete the original session folder after successful upload
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
        let cameraTransform = frame.camera.transform
        
        // Process everything on the background thread
        customQueue.async {
            // Step 1: Create a CIImage from the camera's pixel buffer.
            let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)

            // Step 2: Create a CGImage from the CIImage. This is a crucial intermediate step.
            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                os_log("FATAL: Failed to create CGImage from CIImage.", log: .default, type: .fault)
                return
            }
            
            // Step 3: Create the final, correctly oriented UIImage.
            // The .right orientation is necessary to correct the raw landscape buffer from the camera.
            // Use scale 1.0 to avoid any scaling artifacts
            let correctlyOrientedImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
            
            // Step 4: Resize the new, stable image.
            guard let resizedImage = correctlyOrientedImage.resizedToFit(maxLength: 640) else {
                os_log("FATAL: Image resizing failed. Check the resizedToFit extension.", log: .default, type: .fault)
                return
            }
            
            guard let jpgData = resizedImage.jpegData(compressionQuality: 0.75) else {
                os_log("FATAL: Could not get JPEG data from the resized image.", log: .default, type: .fault)
                return
            }

            // Log pose and image data
            self.logPose(timestamp: timestamp, transform: cameraTransform)
            self.logImage(timestamp: timestamp, jpgData: jpgData)
        }
        
        // Update UI on the main thread
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
    
    // MARK: - File I/O & Zipping
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
            
            // MARK: - ⭐️ MODIFIED: Renamed files to match Locate3D's expected input.
            let fileNames = ["poses.txt", "intrinsics.txt"]
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
            
            // MARK: - ⭐️ REMOVED: All header writing to keep files clean for preprocessing.
            
            // Get the current frame to determine original resolution and intrinsics
            if let currentFrame = sceneView.session.currentFrame {
                let originalIntrinsics = currentFrame.camera.intrinsics
                
                // Get original image dimensions
                let originalWidth = CGFloat(CVPixelBufferGetWidth(currentFrame.capturedImage))
                let originalHeight = CGFloat(CVPixelBufferGetHeight(currentFrame.capturedImage))
                
                // Calculate the actual resize scale we'll use
                let aspectRatio = originalWidth / originalHeight
                var targetSize: CGSize
                
                if originalWidth > originalHeight {
                    targetSize = CGSize(width: TARGET_MAX_LENGTH, height: TARGET_MAX_LENGTH / aspectRatio)
                } else {
                    targetSize = CGSize(width: TARGET_MAX_LENGTH * aspectRatio, height: TARGET_MAX_LENGTH)
                }
                
                // Calculate scaling factors
                let scaleX = targetSize.width / originalWidth
                let scaleY = targetSize.height / originalHeight
                
                // Scale the intrinsics
                let scaledFx = originalIntrinsics.columns.0.x * Float(scaleX)
                let scaledFy = originalIntrinsics.columns.1.y * Float(scaleY)
                let scaledOx = originalIntrinsics.columns.2.x * Float(scaleX)
                let scaledOy = originalIntrinsics.columns.2.y * Float(scaleY)
                
                // MARK: - ⭐️ MODIFIED: Write intrinsics as a single, space-separated line.
                let intrinsicsLine = "\(scaledFx) \(scaledFy) \(scaledOx) \(scaledOy)\n"
                fileHandlers[ARKIT_CAMERA_INTRINSICS].write(intrinsicsLine.data(using: .utf8)!)
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
    
    // MARK: - MODIFIED: Update function to accept a progress handler
    private func zipSessionFolder(at sourceURL: URL?, progressHandler: @escaping (Double) -> Void) -> URL? {
        guard let sourceURL = sourceURL else { return nil }
        
        do {
            let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(sourceURL.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: zipURL)
            
            // Pass the progress handler to the Zip library
            try Zip.zipFiles(paths: [sourceURL], zipFilePath: zipURL, password: nil, progress: { progress in
                // This closure is not guaranteed to be on the main thread.
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
        
        // MARK: - ADDED: Hide and reset progress view
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


// At the bottom of ViewController.swift, outside the class definition
// Improved resize extension
extension UIImage {
    func resizedToFit(maxLength: CGFloat) -> UIImage? {
        guard let cgImage = self.cgImage else {
            os_log("Resize failed: Could not get CGImage.", log: .default, type: .error)
            return nil
        }
        
        // Get the actual pixel dimensions
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)

        // Calculate the new size
        let aspectRatio = originalWidth / originalHeight
        var newSize: CGSize
        
        if originalWidth > originalHeight {
            newSize = CGSize(width: maxLength, height: maxLength / aspectRatio)
        } else {
            newSize = CGSize(width: maxLength * aspectRatio, height: maxLength)
        }
        
        // Create a bitmap context with explicit parameters
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
        
        // Draw the image into the context
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Create the final image
        guard let resizedCGImage = context.makeImage() else {
            os_log("Failed to create resized CGImage", log: .default, type: .error)
            return nil
        }
        
        // Create UIImage with explicit scale of 1.0
        let resizedImage = UIImage(cgImage: resizedCGImage, scale: 1.0, orientation: .up)
        
        return resizedImage
    }
}
