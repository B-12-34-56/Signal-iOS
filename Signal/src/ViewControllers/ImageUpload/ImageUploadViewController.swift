//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import PhotosUI
import SignalUI
import SignalServiceKit

@objcMembers
public class ImageUploadViewController: OWSTableViewController2 {
    private let viewModel = ImageUploadViewModel()
    private var selectedImage: UIImage?
    private var selectedFilter: ImageFilter = .none
    
    // MARK: - UI Components
    private lazy var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = Theme.backgroundColor
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        return imageView
    }()
    
    private lazy var filterStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 8
        return stackView
    }()
    
    private lazy var uploadButton: OWSButton = {
        let button = OWSButton(title: OWSLocalizedString("IMAGE_UPLOAD_BUTTON", comment: "Title for the image upload button")) { [weak self] in
            self?.uploadButtonTapped()
        }
        button.backgroundColor = Theme.accentBlueColor
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.isEnabled = false
        return button
    }()
    
    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .dynamicTypeBody2Clamped
        label.textColor = Theme.secondaryTextAndIconColor
        return label
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = OWSLocalizedString("IMAGE_UPLOAD_TITLE", comment: "Title for the image upload screen")
        setupViews()
        setupConstraints()
        setupGestures()
    }
    
    // MARK: - Setup
    
    private func setupViews() {
        view.backgroundColor = Theme.backgroundColor
        
        // Add filter buttons
        let filters: [(ImageFilter, String)] = [
            (.none, OWSLocalizedString("FILTER_NONE", comment: "No filter option")),
            (.mono, OWSLocalizedString("FILTER_MONO", comment: "Mono filter option")),
            (.vibrant, OWSLocalizedString("FILTER_VIBRANT", comment: "Vibrant filter option")),
            (.sepia, OWSLocalizedString("FILTER_SEPIA", comment: "Sepia filter option"))
        ]
        
        filters.forEach { filter, title in
            let button = createFilterButton(title: title, filter: filter)
            filterStackView.addArrangedSubview(button)
        }
        
        // Add views to hierarchy
        view.addSubview(imageView)
        view.addSubview(filterStackView)
        view.addSubview(uploadButton)
        view.addSubview(statusLabel)
    }
    
    private func setupConstraints() {
        // Image view constraints
        imageView.autoPinEdge(toSuperviewSafeArea: .top, withInset: 16)
        imageView.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 16)
        imageView.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 16)
        imageView.autoSetDimension(.height, toSize: 200) // Fixed height for iPhone SE
        
        // Filter stack view constraints
        filterStackView.autoPinEdge(.top, to: .bottom, of: imageView, withOffset: 16)
        filterStackView.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 16)
        filterStackView.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 16)
        filterStackView.autoSetDimension(.height, toSize: 44)
        
        // Upload button constraints
        uploadButton.autoPinEdge(.top, to: .bottom, of: filterStackView, withOffset: 16)
        uploadButton.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 16)
        uploadButton.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 16)
        uploadButton.autoSetDimension(.height, toSize: 44)
        
        // Status label constraints
        statusLabel.autoPinEdge(.top, to: .bottom, of: uploadButton, withOffset: 16)
        statusLabel.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 16)
        statusLabel.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 16)
    }
    
    private func setupGestures() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(imageViewTapped))
        imageView.addGestureRecognizer(tapGesture)
    }
    
    // MARK: - Actions
    
    @objc private func imageViewTapped() {
        let imagePicker = UIImagePickerController()
        imagePicker.delegate = self
        imagePicker.sourceType = .photoLibrary
        imagePicker.allowsEditing = true
        present(imagePicker, animated: true)
    }
    
    private func createFilterButton(title: String, filter: ImageFilter) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .dynamicTypeBodyClamped
        button.backgroundColor = Theme.backgroundColor
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.layer.borderColor = Theme.accentBlueColor.cgColor
        button.setTitleColor(Theme.accentBlueColor, for: .normal)
        button.tag = filter.rawValue
        button.addTarget(self, action: #selector(filterButtonTapped(_:)), for: .touchUpInside)
        return button
    }
    
    @objc private func filterButtonTapped(_ sender: UIButton) {
        guard let filter = ImageFilter(rawValue: sender.tag),
              let image = selectedImage else { return }
        
        selectedFilter = filter
        updateFilterButtons()
        
        if let filteredImage = viewModel.applyFilter(image, filter: filter) {
            imageView.image = filteredImage
        }
    }
    
    private func updateFilterButtons() {
        filterStackView.arrangedSubviews.forEach { view in
            guard let button = view as? UIButton else { return }
            let isSelected = button.tag == selectedFilter.rawValue
            button.backgroundColor = isSelected ? Theme.accentBlueColor : Theme.backgroundColor
            button.setTitleColor(isSelected ? .white : Theme.accentBlueColor, for: .normal)
        }
    }
    
    private func uploadButtonTapped() {
        guard let image = imageView.image else { return }
        
        // Show loading state
        uploadButton.isEnabled = false
        statusLabel.text = OWSLocalizedString("IMAGE_UPLOAD_STATUS_UPLOADING", comment: "Status message while uploading image")
        
        // Compute image hash
        let imageHash = viewModel.computeImageHash(image)
        
        // Check for duplicate
        AWSService.shared.checkImageSignature(hash: imageHash) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let isDuplicate):
                if isDuplicate {
                    DispatchQueue.main.async {
                        self.uploadButton.isEnabled = true
                        self.statusLabel.text = OWSLocalizedString("IMAGE_UPLOAD_ERROR_DUPLICATE", comment: "Error message for duplicate image")
                    }
                    return
                }
                
                // Upload image if not duplicate
                self.uploadImage(image, hash: imageHash)
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.uploadButton.isEnabled = true
                    self.statusLabel.text = OWSLocalizedString("IMAGE_UPLOAD_ERROR_CHECK_FAILED", comment: "Error message when duplicate check fails")
                    Logger.error("Failed to check image signature: \(error)")
                }
            }
        }
    }
    
    private func uploadImage(_ image: UIImage, hash: String) {
        AWSService.shared.uploadImage(image) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let imageURL):
                // Store image signature
                AWSService.shared.storeImageSignature(hash: hash) { result in
                    switch result {
                    case .success:
                        // Get image tag
                        AWSService.shared.getImageTag(imageURL: imageURL) { [weak self] result in
                            guard let self = self else { return }
                            
                            DispatchQueue.main.async {
                                switch result {
                                case .success(let tag):
                                    self.uploadButton.isEnabled = true
                                    self.statusLabel.text = String(format: OWSLocalizedString("IMAGE_UPLOAD_SUCCESS", comment: "Success message with image tag"), tag)
                                    
                                case .failure(let error):
                                    self.uploadButton.isEnabled = true
                                    self.statusLabel.text = OWSLocalizedString("IMAGE_UPLOAD_ERROR_TAG_FAILED", comment: "Error message when getting image tag fails")
                                    Logger.error("Failed to get image tag: \(error)")
                                }
                            }
                        }
                        
                    case .failure(let error):
                        DispatchQueue.main.async {
                            self.uploadButton.isEnabled = true
                            self.statusLabel.text = OWSLocalizedString("IMAGE_UPLOAD_ERROR_SIGNATURE_FAILED", comment: "Error message when storing image signature fails")
                            Logger.error("Failed to store image signature: \(error)")
                        }
                    }
                }
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.uploadButton.isEnabled = true
                    self.statusLabel.text = OWSLocalizedString("IMAGE_UPLOAD_ERROR_UPLOAD_FAILED", comment: "Error message when image upload fails")
                    Logger.error("Failed to upload image: \(error)")
                }
            }
        }
    }
}

// MARK: - UIImagePickerControllerDelegate

extension ImageUploadViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        
        if let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage {
            selectedImage = image
            imageView.image = image
            uploadButton.isEnabled = true
            statusLabel.text = ""
            updateFilterButtons()
        }
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
} 