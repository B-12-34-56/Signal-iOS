import UIKit
import SignalServiceKit
import SignalUI

class MediaEditingViewController: UIViewController {
    private let viewModel = ImageUploadViewModel()
    private let thread: TSThread
    
    private lazy var sendButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Send", for: .normal)
        button.addTarget(self, action: #selector(onSendTapped), for: .touchUpInside)
        return button
    }()
    
    private var currentImage: UIImage {
        // Get the current image from your image view or editing state
        return imageView.image ?? UIImage()
    }
    
    private lazy var imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        return view
    }()
    
    init(thread: TSThread) {
        self.thread = thread
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
    }
    
    private func setupViews() {
        view.backgroundColor = .systemBackground
        
        view.addSubview(imageView)
        view.addSubview(sendButton)
        
        // Add your layout constraints here
        imageView.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -20),
            
            sendButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sendButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            sendButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            sendButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    @objc private func onSendTapped() {
        sendButton.isEnabled = false
        
        viewModel.uploadImage(currentImage) { [weak self] result in
            guard let self else { return }
            self.sendButton.isEnabled = true
            
            switch result {
            case .success(let s3Key):   self.finishSending(s3Key: s3Key)
            case .failure(let err):     self.presentDuplicateToast(err)
            }
        }
    }
    
    private func presentDuplicateToast(_ err: Error) {
        guard (err as NSError).code == ImageUploadViewModel.UploadError.duplicate.rawValue else {
            showAlert("Image upload failed")
            return
        }
        Toast.show(in: view, text: "Duplicate image – not sent")
        OWSSystemMessageBuilder.insertSystemMessage("Duplicate image blocked", in: thread)
    }
    
    private func finishSending(s3Key: String) {
        // Create and send the message with the S3 key
        let message = TSOutgoingMessage(in: thread, messageBody: nil, attachmentIds: [])
        message.attachmentIds = [s3Key]
        
        // Use Signal's message sending infrastructure
        messageSender.sendMessage(message.asPreparer, success: { [weak self] in
            self?.dismiss(animated: true)
        }, failure: { [weak self] error in
            self?.showAlert("Failed to send message: \(error.localizedDescription)")
        })
    }
    
    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
} 