import UIKit

enum Toast {
    static func show(in parent: UIView, text: String) {
        let label = PaddingLabel()
        label.text = text
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.7)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.alpha = 0
        parent.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -40)
        ])
        UIView.animate(withDuration: 0.3, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 2, options: []) {
                label.alpha = 0
            } completion: { _ in label.removeFromSuperview() }
        }
    }
}

// Helper class for padding
private class PaddingLabel: UILabel {
    private let padding = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetRect = bounds.inset(by: padding)
        let textRect = super.textRect(forBounds: insetRect, limitedToNumberOfLines: numberOfLines)
        let invertedInsets = UIEdgeInsets(
            top: -padding.top,
            left: -padding.left,
            bottom: -padding.bottom,
            right: -padding.right
        )
        return textRect.inset(by: invertedInsets)
    }
    
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: padding))
    }
} 