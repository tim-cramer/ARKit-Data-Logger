import Foundation
import os.log

enum UploadError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case httpError(statusCode: Int, serverMessage: String?)
    case noData
    case fileError(Error)

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
        case .fileError(let error):
            return "File processing error: \(error.localizedDescription)"
        }
    }
}

/// A helper class to handle network requests for uploading data.
class NetworkManager: NSObject, URLSessionTaskDelegate {

    private var progressHandler: ((Float) -> Void)?

    func uploadImages(fileURLs: [URL], to serverEndpoint: String, progressHandler: @escaping (Float) -> Void, completion: @escaping (Result<Void, UploadError>) -> Void) {
        
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
            for fileURL in fileURLs {
                let fileData = try Data(contentsOf: fileURL)
                let fileName = fileURL.lastPathComponent
                
                data.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
                // The server expects the key to be "images"
                data.append("Content-Disposition: form-data; name=\"images\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
                data.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
                data.append(fileData)
            }
            data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        } catch {
            completion(.failure(.fileError(error)))
            return
        }
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60.0 // 60 second timeout for potentially large uploads
        
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
                
                // The server returns 202 Accepted on success
                guard httpResponse.statusCode == 202 else {
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
