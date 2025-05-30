//
// ImageUploadViewController.swift
// Signal
//
// Created for AWS S3 image upload with duplicate detection.
//

import UIKit
import SignalServiceKit

class ImageUploadViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    // UI
    private let imageView = UIImageView()
    private let pickButton = UIButton(type: .system)
    private let uploadButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    
    // State
    private var selectedImage: UIImage? {
        didSet {
            imageView.image = selectedImage
            uploadButton.isEnabled = selectedImage != nil
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Upload Image"
        view.backgroundColor = .systemBackground
        setupUI()
    }
    
    private func setupUI() {
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        
        pickButton.setTitle("Pick Image", for: .normal)
        pickButton.addTarget(self, action: #selector(pickImage), for: .touchUpInside)
        pickButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pickButton)
        
        uploadButton.setTitle("Upload to AWS", for: .normal)
        uploadButton.addTarget(self, action: #selector(uploadImage), for: .touchUpInside)
        uploadButton.isEnabled = false
        uploadButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(uploadButton)
        
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            imageView.heightAnchor.constraint(equalToConstant: 240),
            
            pickButton.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 20),
            pickButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            uploadButton.topAnchor.constraint(equalTo: pickButton.bottomAnchor, constant: 20),
            uploadButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            statusLabel.topAnchor.constraint(equalTo: uploadButton.bottomAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }
    
    @objc private func pickImage() {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        present(picker, animated: true)
    }
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        if let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage {
            selectedImage = image
            statusLabel.text = ""
        }
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
    
    @objc private func uploadImage() {
        guard let image = selectedImage else { return }
        statusLabel.text = "Checking for duplicates..."
        uploadButton.isEnabled = false
        // Compute hash for duplicate detection
        DispatchQueue.global(qos: .userInitiated).async {
            let hash = self.computeImageHash(image)
            DispatchQueue.main.async {
                self.checkDuplicateAndUpload(image: image, hash: hash)
            }
        }
    }
    
    private func computeImageHash(_ image: UIImage) -> String {
        // Use SHA256 of PNG data for simplicity
        guard let data = image.pngData() else { return "" }
        return data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> String in
            let hash = SHA256.hash(data: Data(ptr))
            return hash.map { String(format: "%02x", $0) }.joined()
        }
    }
    
    private func checkDuplicateAndUpload(image: UIImage, hash: String) {
        // TODO: Integrate with real duplicate detection service if available
        // For now, always upload
        statusLabel.text = "Uploading to AWS..."
        uploadToAWS(image: image, hash: hash)
    }
    
    private func uploadToAWS(image: UIImage, hash: String) {
        // TODO: Integrate with real AWS S3 upload logic
        // For now, simulate upload
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            DispatchQueue.main.async {
                self.statusLabel.text = "Upload complete! Hash: \(hash.prefix(8))..."
                self.uploadButton.isEnabled = true
            }
        }
    }
}

import CryptoKit // For SHA256 