import UIKit
import SignalUI

class BlockedImagePlaceholderView: UIView {
    private let imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = Theme.secondaryTextAndIconColor
        imageView.image = UIImage(systemName: "lock.fill")
        return imageView
    }()
    
    private let label: UILabel = {
        let label = UILabel()
        label.text = NSLocalizedString("BLOCKED_IMAGE", comment: "Label shown when an image is blocked")
        label.textAlignment = .center
        label.textColor = Theme.secondaryTextAndIconColor
        label.font = .systemFont(ofSize: 14)
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        backgroundColor = Theme.backgroundColor
        
        addSubview(imageView)
        addSubview(label)
        
        imageView.autoCenterInSuperview()
        imageView.autoSetDimensions(to: CGSize(width: 32, height: 32))
        
        label.autoPinEdge(.top, to: .bottom, of: imageView, withOffset: 8)
        label.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
    }
} 